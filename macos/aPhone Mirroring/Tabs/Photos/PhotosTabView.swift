// PhotosTabView.swift
// aPhone Mirroring
//
// Photos tab: LazyVGrid of square PhotoCell thumbnails (130-240pt, adaptive). Infinite scroll
// sentinel at grid end triggers bridge.loadMorePhotos(). Thumbnails loaded on appear via
// bridge.fetchThumbnail(mediaId:). Clicking opens full photo via bridge.openFullPhoto(mediaId:).
//

import SwiftUI
import AppKit

// MARK: - PhotosTabView

struct PhotosTabView: View {
    let bridge: DataBridgeClient
    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 240), spacing: 8)]

    var body: some View {
        Group {
            if bridge.photos.isEmpty {
                VStack(spacing: 12) {
                    if bridge.isLoading {
                        ProgressView().controlSize(.regular)
                        Text("Loading photos…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(bridge.isConnected ? "No photos" : "Connect your phone to view photos")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(bridge.photos) { photo in
                            PhotoCell(photo: photo, bridge: bridge)
                        }
                        // Sentinel: when this appears in the viewport, load the next page
                        if bridge.photosHasMore {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .onAppear { bridge.loadMorePhotos() }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.17)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PhotoCell

struct PhotoCell: View {
    let photo: BridgePhoto
    let bridge: DataBridgeClient

    var body: some View {
        Button { bridge.openFullPhoto(mediaId: photo.mediaId) } label: {
            // Rectangle with aspectRatio(1) is the reliable way to get square cells in LazyVGrid
            Rectangle()
                .fill(Color(white: 0.22))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let img = photo.thumbnailImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary.opacity(0.4))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if photo.localURL != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.green.opacity(0.85))
                            .padding(5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onAppear { bridge.fetchThumbnail(mediaId: photo.mediaId) }
    }
}
