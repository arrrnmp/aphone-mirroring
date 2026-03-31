//
//  ScrcpyVideoStream.swift
//  aPhone Mirroring
//
//  Reads H.264 video from the scrcpy video socket and renders it via AVSampleBufferDisplayLayer.
//
//  Frame pipeline:
//    1. Read 12-byte header: [pts:8 | size:4] (bit 63 of pts = config flag)
//    2. Config packets → splitAnnexB → SPS/PPS → CMVideoFormatDescription
//    3. Data packets → annexBtoAVCC → CMBlockBuffer → CMSampleBuffer
//    4. kCMSampleAttachmentKey_DisplayImmediately = true → bypass PTS scheduling
//    5. sampleBufferRenderer.enqueue(sb) — AVSampleBufferDisplayLayer manages its queue
//
//  Screenshot support: a persistent VTDecompressionSession decodes every frame on a
//  background VT thread and stores the result in `latestDecodedBuffer` (marked
//  `nonisolated(unsafe)` since VT writes are sequential and screenshot reads are rare).
//  captureCurrentFrame() converts the latest CVPixelBuffer to CGImage via a cached
//  CIContext (Metal GPU context — never recreated per call).
//
//  Rotation: processConfigPacket() re-derives videoSize from CMVideoFormatDescription
//  dimensions on every config packet, including after device rotation.
//

import Foundation
import AVFoundation
import CoreImage
import CoreMedia
import VideoToolbox
import Network

// MARK: - ScrcpyVideoStream

@MainActor
@Observable
final class ScrcpyVideoStream {

    let displayLayer = AVSampleBufferDisplayLayer()

    var videoSize: CGSize = .zero

    private var connection: NWConnection?
    private var readTask: Task<Void, Never>?

    /// Called on the main actor when the video connection drops unexpectedly.
    var onDisconnect: (() -> Void)? = nil

    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    // Persistent decode session for screenshot capture.
    // Decodes every frame in the background and stores the latest CVPixelBuffer.
    // This avoids the deadlock that occurs when creating a VT session on @MainActor on demand.
    private var captureSession: VTDecompressionSession?
    /// Written from the VT decompression callback (background thread); read on @MainActor
    /// for screenshot capture. `nonisolated(unsafe)` opts out of Swift 6 isolation checking —
    /// safe because VT writes are sequential and screenshot reads are rare, never concurrent.
    nonisolated(unsafe) private var latestDecodedBuffer: CVPixelBuffer?
    // @ObservationIgnored required because @Observable macro cannot track lazy stored properties.
    @ObservationIgnored private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Counters for log
    private var configPacketCount = 0
    private var dataPacketCount = 0
    private var droppedFrameCount = 0
    private var enqueuedFrameCount = 0

    init() {
        displayLayer.videoGravity = .resize
        displayLayer.backgroundColor = CGColor.clear
        log("ScrcpyVideoStream init, displayLayer=\(displayLayer)", level: .debug)
    }

    // MARK: - Start / Stop

    func start(connection: NWConnection, width: Int, height: Int) async {
        self.connection = connection
        videoSize = CGSize(width: width, height: height)
        configPacketCount = 0
        dataPacketCount = 0
        droppedFrameCount = 0
        enqueuedFrameCount = 0
        log("VideoStream start — \(width)×\(height)")

        // Reset decoder state for fresh session
        displayLayer.flush()
        formatDescription = nil
        sps = nil
        pps = nil
        tearDownCaptureSession()

        // Run the read loop on a detached task so it never blocks @MainActor
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.readLoop()
        }
    }

    func stop() async {
        log("VideoStream stop — enqueued=\(enqueuedFrameCount) dropped=\(droppedFrameCount)")
        onDisconnect = nil
        readTask?.cancel()
        readTask = nil
        connection?.cancel()
        connection = nil
        displayLayer.flush()
        formatDescription = nil
        sps = nil
        pps = nil
        tearDownCaptureSession()
    }

    // MARK: - Read loop (runs off main actor)

    private func readLoop() async {
        guard let conn = connection else {
            await MainActor.run { log("readLoop: no connection", level: .error) }
            return
        }
        await MainActor.run { log("readLoop: started") }

        while !Task.isCancelled {
            do {
                // Read 12-byte frame header
                let headerData = try await conn.receiveExactly(12)

                let rawPTS     = headerData.loadBigEndianUInt64(at: 0)
                let isConfig   = (rawPTS >> 63) & 1 == 1
                let packetSize = Int(headerData.loadBigEndianUInt32(at: 8))

                guard packetSize > 0, packetSize < 10_000_000 else {
                    await MainActor.run {
                        log("readLoop: bad packetSize=\(packetSize) — skipping", level: .warn)
                    }
                    continue
                }

                let payload = try await conn.receiveExactly(packetSize)

                if isConfig {
                    await MainActor.run {
                        self.configPacketCount += 1
                        log("Config packet #\(self.configPacketCount) (\(packetSize) bytes)", level: .debug)
                        self.processConfigPacket(payload)
                    }
                } else {
                    let pts = CMTime(value: CMTimeValue(rawPTS & 0x3FFF_FFFF_FFFF_FFFF),
                                     timescale: 1_000_000)
                    await MainActor.run {
                        self.dataPacketCount += 1
                        if self.dataPacketCount <= 5 || self.dataPacketCount % 100 == 0 {
                            log("Frame #\(self.dataPacketCount) (\(packetSize) bytes) pts=\(pts.seconds.formatted(.number.precision(.fractionLength(3))))", level: .debug)
                        }
                        self.processDataPacket(payload, pts: pts)
                    }
                }
            } catch {
                let cancelled = Task.isCancelled
                await MainActor.run { [weak self] in
                    log("readLoop error: \(error) — stopping", level: .error)
                    if !cancelled { self?.onDisconnect?() }
                }
                break
            }
        }
        await MainActor.run { log("readLoop: exited (cancelled=\(Task.isCancelled))") }
    }

    // MARK: - Config packet: SPS + PPS in Annex B

    private func processConfigPacket(_ data: Data) {
        let nalUnits = splitAnnexB(data)
        log("Config: \(nalUnits.count) NAL units", level: .debug)
        for nal in nalUnits {
            guard !nal.isEmpty else { continue }
            let nalType = nal[nal.startIndex] & 0x1F
            log("  NAL type=\(nalType) size=\(nal.count)", level: .debug)
            switch nalType {
            case 7:
                sps = Data(nal)  // Force contiguous copy
                formatDescription = nil
                log("  → SPS stored (\(nal.count) bytes)", level: .debug)
            case 8:
                pps = Data(nal)  // Force contiguous copy
                formatDescription = nil
                log("  → PPS stored (\(nal.count) bytes)", level: .debug)
            default:
                break
            }
        }
        if let s = sps, let p = pps {
            formatDescription = makeFormatDescription(sps: s, pps: p)
            if let desc = formatDescription {
                log("Format description built OK", level: .ok)
                let dim = CMVideoFormatDescriptionGetDimensions(desc)
                let newSize = CGSize(width: CGFloat(dim.width), height: CGFloat(dim.height))
                if newSize != videoSize {
                    videoSize = newSize
                    log("Video size updated to \(dim.width)×\(dim.height)", level: .ok)
                }
                setupCaptureSession(desc)
            } else {
                log("Format description build FAILED", level: .error)
            }
        } else {
            log("Config: waiting for both SPS(\(sps != nil)) and PPS(\(pps != nil))", level: .warn)
        }
    }

    // MARK: - Data packet: one complete encoded frame in Annex B

    private func processDataPacket(_ data: Data, pts: CMTime) {
        guard let desc = formatDescription else {
            if dataPacketCount <= 3 {
                log("Frame #\(dataPacketCount) dropped — no formatDescription yet", level: .warn)
            }
            droppedFrameCount += 1
            return
        }

        let avcc = annexBtoAVCC(data)
        guard !avcc.isEmpty else {
            log("Frame #\(dataPacketCount): annexBtoAVCC returned empty", level: .warn)
            droppedFrameCount += 1
            return
        }

        // Copy into a CMBlockBuffer that owns its memory (not a pointer into `avcc`)
        var blockBuffer: CMBlockBuffer?
        let copyStatus = avcc.withUnsafeBytes { ptr -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,          // let CMBlockBuffer allocate
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avcc.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }
        guard copyStatus == noErr, let block = blockBuffer else {
            log("CMBlockBufferCreate failed: \(copyStatus)", level: .error)
            return
        }

        // Copy the actual bytes in
        let fillStatus = avcc.withUnsafeBytes { ptr -> OSStatus in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard fillStatus == noErr else {
            log("CMBlockBufferReplaceDataBytes failed: \(fillStatus)", level: .error)
            return
        }

        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sb = sampleBuffer else {
            log("CMSampleBufferCreate failed: \(sbStatus)", level: .error)
            return
        }

        // Display immediately — bypass PTS scheduling entirely
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        // Enqueue unconditionally — AVSampleBufferDisplayLayer manages its own internal queue.
        // Checking isReadyForMoreMediaData and flushing on "not ready" destroys the decode
        // pipeline on every frame and causes single-digit framerate.
        displayLayer.sampleBufferRenderer.enqueue(sb)

        // Decode in parallel into the capture session so screenshots always have a fresh buffer.
        if let sess = captureSession {
            VTDecompressionSessionDecodeFrame(sess, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { [weak self] _, _, imageBuffer, _, _ in
                guard let pb = imageBuffer else { return }
                self?.latestDecodedBuffer = pb
            }
        }
        enqueuedFrameCount += 1

        // Only flush on an actual renderer error
        if let err = displayLayer.error {
            log("displayLayer.error: \(err) — flushing", level: .error)
            displayLayer.flush()
        }
    }

    // MARK: - H.264 helpers

    private func splitAnnexB(_ data: Data) -> [Data] {
        // Work on a contiguous copy to ensure integer indexing is valid
        let bytes = data.startIndex == 0 ? data : Data(data)
        var result: [Data] = []
        var i = 0
        var nalStart = -1

        while i < bytes.count {
            let remaining = bytes.count - i
            if remaining >= 4 && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                if nalStart >= 0 { result.append(Data(bytes[nalStart..<i])) }
                nalStart = i + 4
                i += 4
            } else if remaining >= 3 && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                if nalStart >= 0 { result.append(Data(bytes[nalStart..<i])) }
                nalStart = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if nalStart >= 0 && nalStart < bytes.count {
            result.append(Data(bytes[nalStart...]))
        }
        return result
    }

    private func annexBtoAVCC(_ data: Data) -> Data {
        let nals = splitAnnexB(data)
        var result = Data()
        result.reserveCapacity(data.count + nals.count * 4)
        for nal in nals where !nal.isEmpty {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { result.append(contentsOf: $0) }
            result.append(nal)
        }
        return result
    }

    private func makeFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        let spsBytes = Array(sps)
        let ppsBytes = Array(pps)
        var desc: CMVideoFormatDescription?
        spsBytes.withUnsafeBufferPointer { spsBuf in
            ppsBytes.withUnsafeBufferPointer { ppsBuf in
                var ptrs: [UnsafePointer<UInt8>] = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                var sizes: [Int] = [spsBytes.count, ppsBytes.count]
                ptrs.withUnsafeMutableBufferPointer { ptrBuf in
                    sizes.withUnsafeMutableBufferPointer { sizeBuf in
                        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: ptrBuf.baseAddress!,
                            parameterSetSizes: sizeBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &desc
                        )
                        if status != noErr {
                            log("CMVideoFormatDescriptionCreateFromH264ParameterSets: \(status)", level: .error)
                        }
                    }
                }
            }
        }
        return desc
    }

    // MARK: - Screenshot

    /// Returns a CGImage from the most recently decoded frame.
    /// The persistent capture session keeps `latestDecodedBuffer` current on every frame.
    /// No command is sent to the device.
    func captureCurrentFrame() -> CGImage? {
        guard let pb = latestDecodedBuffer else { return nil }
        let ci = CIImage(cvPixelBuffer: pb)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    // MARK: - Capture session lifecycle

    private func setupCaptureSession(_ desc: CMVideoFormatDescription) {
        tearDownCaptureSession()
        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: pixelAttrs as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        if status == noErr { captureSession = session }
        else { log("Screenshot capture session create failed: \(status)", level: .warn) }
    }

    private func tearDownCaptureSession() {
        if let sess = captureSession { VTDecompressionSessionInvalidate(sess) }
        captureSession      = nil
        latestDecodedBuffer = nil
    }
}
