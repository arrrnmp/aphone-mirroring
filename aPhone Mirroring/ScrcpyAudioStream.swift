//
//  ScrcpyAudioStream.swift
//  Scrcpy SwiftUI
//
//  Reads raw PCM audio from the scrcpy audio socket and plays it
//  through AVAudioEngine. The device sends s16le interleaved stereo
//  at 48 kHz; we convert to Float32 planar for AVAudioPlayerNode.
//
//  Stream layout (same frame-header format as video):
//    • 12-byte codec metadata block  (codec_id:4 + extra:8)
//    • Repeated frames:  [pts:8 | size:4] + payload
//      – config flag = bit 63 of pts (skipped for raw PCM)
//      – data frames  = raw s16le stereo PCM payload
//

import Foundation
import AVFoundation
import Network

// MARK: - ScrcpyAudioStream

@MainActor
final class ScrcpyAudioStream {

    var onDisconnect: (() -> Void)?

    private var readTask: Task<Void, Never>?
    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    // Float32 non-interleaved stereo 48 kHz — the macOS standard playback format.
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    // MARK: - Lifecycle

    func start(connection: NWConnection) async {
        setupEngine()
        startReadLoop(connection: connection)
    }

    func stop() async {
        readTask?.cancel()
        readTask = nil
        onDisconnect = nil
        playerNode.stop()
        if engine.isRunning { engine.stop() }
    }

    // MARK: - Audio engine

    private func setupEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: playFormat)
        do {
            try engine.start()
            playerNode.play()
        } catch {
            log("Audio engine start failed: \(error)", level: .error)
        }
    }

    // MARK: - Read loop (detached — never blocks @MainActor)

    private func startReadLoop(connection: NWConnection) {
        // Capture the player node and format so the hot path can run entirely
        // off the main actor without needing a hop back for each audio frame.
        // AVAudioPlayerNode is an ObjC object and scheduleBuffer is thread-safe.
        let node   = playerNode
        let format = playFormat

        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // 12-byte codec metadata (mirrors the video stream's initial block).
                // For raw PCM: bytes 0-3 = codec_id, bytes 4-11 = sample_rate + channels
                // (or may be zero-filled; format is fixed at s16le/48 kHz/stereo anyway).
                let meta    = try await connection.receiveExactly(12)
                let codecID = meta.loadBigEndianUInt32(at: 0)
                let extra1  = meta.loadBigEndianUInt32(at: 4)
                let extra2  = meta.loadBigEndianUInt32(at: 8)
                await MainActor.run {
                    let tag = String(bytes: [
                        UInt8((codecID >> 24) & 0xFF), UInt8((codecID >> 16) & 0xFF),
                        UInt8((codecID >>  8) & 0xFF), UInt8( codecID        & 0xFF)
                    ], encoding: .ascii) ?? "????"
                    log("Audio codec: \(tag)  extra: \(extra1) / \(extra2)", level: .ok)
                }

                // Frame loop
                while !Task.isCancelled {
                    let header   = try await connection.receiveExactly(12)
                    let pts      = header.loadBigEndianUInt64(at: 0)
                    let size     = Int(header.loadBigEndianUInt32(at: 8))
                    let isConfig = (pts >> 63) != 0

                    guard size > 0, size < 4_000_000 else { continue }
                    let payload = try await connection.receiveExactly(size)

                    // Config packets carry codec-specific init data — skip for raw PCM.
                    if !isConfig {
                        Self.schedulePCM(payload, on: node, format: format)
                    }
                }

            } catch {
                let cancelled = Task.isCancelled
                await MainActor.run { [weak self] in
                    if !cancelled {
                        log("Audio stream error: \(error)", level: .error)
                        self?.onDisconnect?()
                    }
                }
            }
        }
    }

    // MARK: - PCM scheduling (called from background thread — no actor hop needed)

    /// Converts s16le interleaved stereo → Float32 planar and hands the buffer
    /// to AVAudioPlayerNode. Called entirely off the main actor; AVAudioPlayerNode
    /// is thread-safe for scheduleBuffer calls.
    private nonisolated static func schedulePCM(_ data: Data,
                                     on node: AVAudioPlayerNode,
                                     format: AVAudioFormat) {
        // Each frame = 2 channels × 2 bytes = 4 bytes total
        let frameCount = data.count / 4
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount))
        else { return }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { raw in
            guard let s16 = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            let L = buffer.floatChannelData![0]
            let R = buffer.floatChannelData![1]
            for i in 0..<frameCount {
                // Little-endian s16 → [-1, 1] float.  Apple Silicon & x86 are both LE.
                L[i] = Float(s16[i * 2])     / 32_767.0
                R[i] = Float(s16[i * 2 + 1]) / 32_767.0
            }
        }

        node.scheduleBuffer(buffer)
    }
}
