//
//  NWConnectionExtensions.swift
//  Scrcpy SwiftUI
//
//  Async helpers on NWConnection and Data for the scrcpy protocol.
//

import Foundation
import Network

// MARK: - NWConnection async receive

extension NWConnection {

    /// Reads exactly `count` bytes, accumulating across multiple receives.
    func receiveExactly(_ count: Int) async throws -> Data {
        var accumulated = Data()
        accumulated.reserveCapacity(count)

        while accumulated.count < count {
            let needed = count - accumulated.count
            let chunk = try await receiveSome(minimum: 1, maximum: needed)
            accumulated.append(chunk)
        }
        return accumulated
    }

    /// Reads between 1 and `maxLength` bytes — returns as soon as any bytes arrive.
    func receiveAvailable(maxLength: Int) async throws -> Data {
        return try await receiveSome(minimum: 1, maximum: maxLength)
    }

    private func receiveSome(minimum: Int, maximum: Int) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: NWError.posix(.ECONNABORTED))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

// MARK: - Data big-endian readers

extension Data {
    func loadBigEndianUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func loadBigEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset+1]) << 16
        | UInt32(self[offset+2]) << 8 | UInt32(self[offset+3])
    }

    func loadBigEndianUInt64(at offset: Int) -> UInt64 {
        UInt64(loadBigEndianUInt32(at: offset)) << 32
        | UInt64(loadBigEndianUInt32(at: offset + 4))
    }
}
