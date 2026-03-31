//
//  ScrcpyAudioStream.swift
//  aPhone Mirroring
//
//  Reads raw PCM audio from the scrcpy audio socket and plays it via AVAudioEngine.
//
//  Architecture: AVAudioSourceNode (pull model) + lock-protected ring buffer.
//
//  Why this beats scheduleBuffer:
//    scheduleBuffer inserts silence whenever the next buffer hasn't arrived yet,
//    causing the crackling heard with USB jitter. AVAudioSourceNode never gaps —
//    the render callback fills from the ring buffer or outputs silence seamlessly.
//
//  Real-time safety:
//    The render callback uses os_unfair_lock_trylock — it never blocks the real-time
//    audio thread. If the writer holds the lock (s16le→Float32 conversion, ~µs),
//    the callback outputs silence for that render period and retries next callback
//    (~10 ms later). This eliminates the priority-inversion crackling that a
//    blocking os_unfair_lock_lock call caused under USB burst delivery.
//
//    The write side performs s16le→Float32 conversion outside the lock into a
//    pre-allocated scratch buffer, so the lock is held only for the fast Float copy
//    + index update — minimising contention with the render callback.
//
//  scrcpy raw audio format (from AudioConfig.java):
//    • 12-byte stream header  (codec_id:4 + reserved:8)
//    • Repeated frames: [pts:8 | size:4] + payload
//      – config flag = bit 63 of pts (no config packets for raw PCM in practice)
//      – payload = s16le interleaved stereo 48 000 Hz, ≤ 1 024 frames per chunk
//

import Foundation
import AVFoundation
import Network

// MARK: - AudioRingBuffer

/// Thread-safe SPSC ring buffer for Float32 non-interleaved stereo audio.
/// Writer: network decode task.  Reader: AVAudioSourceNode render callback.
///
/// Real-time safety: the render callback uses trylock and outputs silence rather
/// than blocking if the writer holds the lock. The write side moves s16le→Float32
/// conversion outside the lock to keep lock hold time as short as possible.
private final class AudioRingBuffer: @unchecked Sendable {

    private let capacity: Int
    private var L: [Float32]
    private var R: [Float32]
    private var writeIdx = 0
    private var readIdx  = 0
    private var count    = 0
    private var lock     = os_unfair_lock()

    // Pre-allocated scratch buffers for s16le→Float32 conversion.
    // Written only by the single writer thread — no races with the reader.
    private var tempL: [Float32]
    private var tempR: [Float32]

    init(capacity: Int) {
        self.capacity = capacity
        L     = [Float32](repeating: 0, count: capacity)
        R     = [Float32](repeating: 0, count: capacity)
        tempL = [Float32](repeating: 0, count: capacity)
        tempR = [Float32](repeating: 0, count: capacity)
    }

    // MARK: Writer side (network task — non-real-time)

    /// Convert s16le interleaved stereo payload and append to ring buffer.
    ///
    /// Conversion is performed outside the lock to minimise lock hold time.
    /// When the payload exceeds available capacity, the OLDEST frames are
    /// flushed to keep audio current (low latency). When the payload itself
    /// exceeds the ring capacity, only the LATEST (tail) frames are kept.
    func write(s16lePayload payload: Data) {
        let frameCount = payload.count / 4   // 2 ch × 2 bytes
        guard frameCount > 0 else { return }

        // Always keep the most recent audio: if payload > capacity, skip the
        // leading (oldest) frames so we write the tail of the payload.
        let toWrite   = min(frameCount, capacity)
        let srcOffset = frameCount - toWrite

        // Step 1: s16le → Float32 conversion outside the lock.
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let s16 = base.assumingMemoryBound(to: Int16.self)
            for i in 0..<toWrite {
                tempL[i] = Float(s16[(srcOffset + i) &* 2])      / 32_767.0
                tempR[i] = Float(s16[(srcOffset + i) &* 2 &+ 1]) / 32_767.0
            }
        }

        // Step 2: Copy converted floats into the ring buffer under the lock.
        // Flush oldest frames first if the incoming batch would overflow.
        os_unfair_lock_lock(&lock)
        if count + toWrite > capacity {
            let excess = min(count + toWrite - capacity, count)
            readIdx = (readIdx + excess) % capacity
            count  -= excess
        }
        for i in 0..<toWrite {
            let pos = (writeIdx + i) % capacity
            L[pos] = tempL[i]
            R[pos] = tempR[i]
        }
        writeIdx = (writeIdx + toWrite) % capacity
        count   += toWrite
        os_unfair_lock_unlock(&lock)
    }

    // MARK: Reader side (render callback — real-time thread)

    /// Fill an AudioBufferList with `frameCount` Float32 non-interleaved frames.
    ///
    /// Uses trylock to avoid ever blocking the real-time audio thread. If the
    /// write side holds the lock, this render period outputs silence; data will
    /// be available next callback (~10 ms later once the writer finishes its µs work).
    func read(into abl: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let abp = UnsafeMutableAudioBufferListPointer(abl)
        guard abp.count >= 2,
              let lOut = abp[0].mData?.assumingMemoryBound(to: Float32.self),
              let rOut = abp[1].mData?.assumingMemoryBound(to: Float32.self)
        else { return }

        // trylock: if the write side holds the lock, output silence and return
        // immediately — never block the real-time thread (priority inversion).
        guard os_unfair_lock_trylock(&lock) else {
            for i in 0..<frameCount { lOut[i] = 0; rOut[i] = 0 }
            return
        }

        let toRead = min(frameCount, count)
        for i in 0..<toRead {
            let pos = (readIdx + i) % capacity
            lOut[i] = L[pos]
            rOut[i] = R[pos]
        }
        readIdx = (readIdx + toRead) % capacity
        count  -= toRead
        os_unfair_lock_unlock(&lock)

        // Silence for underrun — written outside the lock (caller's memory).
        for i in toRead..<frameCount {
            lOut[i] = 0
            rOut[i] = 0
        }
    }

    // MARK: Reset (call only before reader/writer tasks start)

    func reset() {
        writeIdx = 0
        readIdx  = 0
        count    = 0
        for i in 0..<capacity { L[i] = 0; R[i] = 0 }
    }
}

// MARK: - ScrcpyAudioStream

@MainActor
final class ScrcpyAudioStream {

    var onDisconnect: (() -> Void)?

    private var readTask:    Task<Void, Never>?
    private var engine:      AVAudioEngine = AVAudioEngine()
    private var sourceNode:  AVAudioSourceNode?
    // Token for the AVAudioEngineConfigurationChange observer — removed in stop().
    private var engineConfigObserver: (any NSObjectProtocol)?

    // scrcpy AudioConfig.java: 48 000 Hz, stereo, PCM_16BIT.
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate:   48_000,
        channels:     2,
        interleaved:  false
    )!

    // Ring buffer: 2 s @ 48 kHz — comfortably absorbs USB jitter.
    private let ring = AudioRingBuffer(capacity: 48_000 * 2)

    // MARK: - Lifecycle

    func start(connection: NWConnection) async {
        ring.reset()
        buildEngine()
        startReader(connection: connection)
    }

    func stop() async {
        readTask?.cancel()
        readTask     = nil
        onDisconnect = nil

        // Remove the configuration-change observer before stopping the engine
        // so the handler doesn't try to restart an intentionally stopped engine.
        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            engineConfigObserver = nil
        }

        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
    }

    /// Mute or unmute audio without stopping the stream.
    func setAudioEnabled(_ enabled: Bool) {
        engine.mainMixerNode.outputVolume = enabled ? 1.0 : 0.0
    }

    // MARK: - Engine

    private func buildEngine() {
        // Remove any stale observer before creating a new engine.
        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            engineConfigObserver = nil
        }

        // Fresh engine each connection — avoids accumulated state from prior sessions.
        let eng     = AVAudioEngine()
        engine      = eng
        let fmt     = Self.format
        let ringRef = ring

        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, audioBufferList in
            ringRef.read(into: audioBufferList, frameCount: Int(frameCount))
            return noErr
        }

        sourceNode = node
        eng.attach(node)
        eng.connect(node, to: eng.mainMixerNode, format: fmt)

        // Restart the engine when audio hardware configuration changes.
        // Without this handler, connecting/disconnecting headphones, switching
        // Bluetooth audio devices, or changing the system default output causes
        // AVAudioEngine to stop permanently — audio is dead until reconnect.
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: eng,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.engine === eng else { return }
                do {
                    try self.engine.start()
                    log("Audio engine restarted after configuration change", level: .ok)
                } catch {
                    log("Audio engine restart failed: \(error)", level: .error)
                }
            }
        }

        do {
            try eng.start()
        } catch {
            log("Audio engine start failed: \(error)", level: .error)
        }
    }

    // MARK: - Network reader

    private func startReader(connection: NWConnection) {
        let ringRef = ring
        let fireDisconnect: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.onDisconnect?() }
        }

        readTask = Task.detached(priority: .userInitiated) {
            do {
                // 12-byte stream header: codec_id(4) + reserved(8)
                let meta    = try await connection.receiveExactly(12)
                let codecID = meta.loadBigEndianUInt32(at: 0)
                let tag     = String(bytes: [
                    UInt8((codecID >> 24) & 0xFF), UInt8((codecID >> 16) & 0xFF),
                    UInt8((codecID >>  8) & 0xFF), UInt8( codecID        & 0xFF)
                ], encoding: .ascii) ?? "????"
                await MainActor.run { log("Audio codec: \(tag) (pull-mode ring buffer)", level: .ok) }

                while !Task.isCancelled {
                    // Frame header: pts(8) + size(4)
                    let header   = try await connection.receiveExactly(12)
                    let pts      = header.loadBigEndianUInt64(at: 0)
                    let size     = Int(header.loadBigEndianUInt32(at: 8))
                    let isConfig = (pts >> 63) != 0

                    // Always drain payload to keep the framing in sync.
                    guard size > 0 else { continue }
                    let payload = try await connection.receiveExactly(size)

                    // Raw PCM has no meaningful config packets; skip any that appear.
                    guard !isConfig else { continue }

                    ringRef.write(s16lePayload: payload)
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { log("Audio error: \(error)", level: .error) }
                    fireDisconnect()
                }
            }
        }
    }
}
