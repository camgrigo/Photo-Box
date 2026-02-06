//
//  DuplicateVideoCard.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import SwiftUI
import Photos

struct DuplicateVideoCard: View {
    let asset: PHAsset
    let isSelected: Bool
    let onToggle: () -> Void
    var onChangeDate: (() -> Void)?

    @State private var thumbnail: UIImage?
    @State private var fileSize: String = "\u{2026}"

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(2/3, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(.gray.opacity(0.3))
                        .aspectRatio(2/3, contentMode: .fit)
                        .overlay { ProgressView().tint(.white) }
                }

                if isSelected {
                    Color.blue.opacity(0.3)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white, .blue)
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                if let date = asset.creationDate {
                    Text(date, format: .dateTime.month().day().year())
                        .font(.caption2)
                        .foregroundStyle(.white)
                }
                HStack {
                    Text(formatDuration(asset.duration))
                    Spacer()
                    Text(fileSize)
                }
                .font(.caption2)
                .foregroundStyle(.gray)

                Text("\(asset.pixelWidth)\u{00D7}\(asset.pixelHeight)")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .contextMenu {
            Button {
                onToggle()
            } label: {
                Label(isSelected ? "Deselect" : "Select for Deletion", systemImage: isSelected ? "xmark.circle" : "checkmark.circle")
            }
            if let onChangeDate {
                Button {
                    onChangeDate()
                } label: {
                    Label("Change Date", systemImage: "calendar")
                }
            }
            Button {
                Task {
                    try? await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetChangeRequest(for: asset)
                        request.isFavorite = !asset.isFavorite
                    }
                }
            } label: {
                Label(asset.isFavorite ? "Unfavorite" : "Favorite", systemImage: asset.isFavorite ? "heart.slash" : "heart")
            }
        }
        .task {
            await loadThumbnail()
            loadFileSize()
        }
    }

    private func loadThumbnail() async {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 300, height: 450),
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            thumbnail = image
        }
    }

    private func loadFileSize() {
        guard let resource = PHAssetResource.assetResources(for: asset).first,
              let size = resource.value(forKey: "fileSize") as? Int64 else { return }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        fileSize = formatter.string(fromByteCount: size)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
