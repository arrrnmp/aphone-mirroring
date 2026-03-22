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
/// Lock held only for O(n) sample copy — microsecond durations in practice.
private final class AudioRingBuffer: @unchecked Sendable {

    private let capacity: Int
    private var L: [Float32]   // left channel
    private var R: [Float32]   // right channel
    private var writeIdx = 0
    private var readIdx  = 0
    private var count    = 0   // frames currently buffered
    private var lock     = os_unfair_lock()

    init(capacity: Int) {
        self.capacity = capacity
        L = [Float32](repeating: 0, count: capacity)
        R = [Float32](repeating: 0, count: capacity)
    }

    // MARK: Writer side

    /// Convert s16le interleaved stereo payload and append to ring buffer.
    /// On overflow, flushes oldest frames to keep audio current (low latency).
    func write(s16lePayload payload: Data) {
        let frameCount = payload.count / 4  // 2 ch × 2 bytes
        guard frameCount > 0 else { return }

        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let s16 = base.assumingMemoryBound(to: Int16.self)

            os_unfair_lock_lock(&lock)
            // If incoming frames would overflow, flush oldest to keep buffer current
            if count + frameCount > capacity {
                let excess = count + frameCount - capacity
                readIdx = (readIdx + excess) % capacity
                count  -= excess
            }
            let toWrite = min(frameCount, capacity)
            for i in 0..<toWrite {
                let pos = (writeIdx + i) % capacity
                L[pos] = Float(s16[i &* 2])      / 32_767.0
                R[pos] = Float(s16[i &* 2 &+ 1]) / 32_767.0
            }
            writeIdx = (writeIdx + toWrite) % capacity
            count   += toWrite
            os_unfair_lock_unlock(&lock)
        }
    }

    // MARK: Reader side (render callback — real-time thread)

    /// Fill an AudioBufferList with `frameCount` Float32 non-interleaved frames.
    /// Underrun positions are filled with silence.
    func read(into abl: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let abp = UnsafeMutableAudioBufferListPointer(abl)
        guard abp.count >= 2,
              let lOut = abp[0].mData?.assumingMemoryBound(to: Float32.self),
              let rOut = abp[1].mData?.assumingMemoryBound(to: Float32.self)
        else { return }

        os_unfair_lock_lock(&lock)
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

    // MARK: Reset

    func reset() {
        os_unfair_lock_lock(&lock)
        writeIdx = 0
        readIdx  = 0
        count    = 0
        for i in 0..<capacity { L[i] = 0; R[i] = 0 }
        os_unfair_lock_unlock(&lock)
    }
}

// MARK: - ScrcpyAudioStream

@MainActor
final class ScrcpyAudioStream {

    var onDisconnect: (() -> Void)?

    private var readTask:    Task<Void, Never>?
    private var engine:     AVAudioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

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
        // Fresh engine each connection — avoids accumulated state from prior sessions
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
