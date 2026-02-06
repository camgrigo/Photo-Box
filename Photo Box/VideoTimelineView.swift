//
//  VideoTimelineView.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import SwiftUI
import AVFoundation
import CoreMedia

struct VideoTimelineView: View {
    let asset: AVAsset
    let duration: CMTime

    @Binding var trimStart: CMTime
    @Binding var trimEnd: CMTime
    @Binding var splitPoints: [CMTime]
    @Binding var playheadPosition: CMTime

    let mode: EditMode
    let onSeek: (CMTime) -> Void

    enum EditMode {
        case trim
        case split
    }

    @State private var thumbnails: [UIImage] = []
    @State private var isDraggingStart = false
    @State private var isDraggingEnd = false

    private let thumbnailCount = 20
    private let timelineHeight: CGFloat = 60
    private let handleWidth: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width

            ZStack(alignment: .leading) {
                // Filmstrip
                filmstrip(width: totalWidth)

                // Overlays depend on mode
                if mode == .trim {
                    trimOverlay(width: totalWidth)
                } else {
                    splitOverlay(width: totalWidth)
                }

                // Playhead
                playhead(width: totalWidth)
            }
            .frame(height: timelineHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(tapGesture(width: totalWidth))
        }
        .frame(height: timelineHeight)
        .task {
            await generateThumbnails()
        }
    }

    // MARK: - Filmstrip

    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(thumbnails.indices, id: \.self) { index in
                Image(uiImage: thumbnails[index])
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width / CGFloat(max(thumbnails.count, 1)), height: timelineHeight)
                    .clipped()
            }
        }
    }

    // MARK: - Trim

    private func trimOverlay(width: CGFloat) -> some View {
        let durationSeconds = duration.seconds
        let startFraction = durationSeconds > 0 ? trimStart.seconds / durationSeconds : 0
        let endFraction = durationSeconds > 0 ? trimEnd.seconds / durationSeconds : 1

        let startX = startFraction * Double(width)
        let endX = endFraction * Double(width)

        return ZStack(alignment: .leading) {
            // Dimmed areas outside trim
            Rectangle()
                .fill(.black.opacity(0.6))
                .frame(width: max(startX, 0))

            Rectangle()
                .fill(.black.opacity(0.6))
                .frame(width: max(Double(width) - endX, 0))
                .offset(x: endX)

            // Trim border
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow, lineWidth: 3)
                .frame(width: max(endX - startX, 0))
                .offset(x: startX)

            // Start handle
            trimHandle(color: .yellow)
                .offset(x: startX - handleWidth / 2)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            isDraggingStart = true
                            let fraction = max(0, min(value.location.x / width, CGFloat(endFraction) - 0.01))
                            trimStart = CMTime(seconds: Double(fraction) * durationSeconds, preferredTimescale: 600)
                            onSeek(trimStart)
                        }
                        .onEnded { _ in isDraggingStart = false }
                )

            // End handle
            trimHandle(color: .yellow)
                .offset(x: endX - handleWidth / 2)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            isDraggingEnd = true
                            let fraction = max(CGFloat(startFraction) + 0.01, min(value.location.x / width, 1))
                            trimEnd = CMTime(seconds: Double(fraction) * durationSeconds, preferredTimescale: 600)
                            onSeek(trimEnd)
                        }
                        .onEnded { _ in isDraggingEnd = false }
                )
        }
    }

    private func trimHandle(color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(width: handleWidth, height: timelineHeight)
            .overlay {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.black.opacity(0.3))
                    .frame(width: 3, height: 20)
            }
    }

    // MARK: - Split

    private func splitOverlay(width: CGFloat) -> some View {
        let durationSeconds = duration.seconds

        return ForEach(splitPoints.indices, id: \.self) { index in
            let fraction = durationSeconds > 0 ? splitPoints[index].seconds / durationSeconds : 0
            let x = fraction * Double(width)

            Rectangle()
                .fill(Color.red)
                .frame(width: 3, height: timelineHeight)
                .offset(x: x - 1.5)
                .overlay(alignment: .top) {
                    Image(systemName: "scissors")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .offset(x: x - 1.5, y: -14)
                }
                .onTapGesture {
                    splitPoints.remove(at: index)
                }
        }
    }

    // MARK: - Playhead

    private func playhead(width: CGFloat) -> some View {
        let durationSeconds = duration.seconds
        let fraction = durationSeconds > 0 ? playheadPosition.seconds / durationSeconds : 0
        let x = fraction * Double(width)

        return Rectangle()
            .fill(.white)
            .frame(width: 2, height: timelineHeight + 8)
            .offset(x: x - 1)
            .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private func tapGesture(width: CGFloat) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let fraction = value.location.x / width
                let time = CMTime(seconds: Double(fraction) * duration.seconds, preferredTimescale: 600)

                if mode == .split {
                    // Check if tapping near an existing marker
                    let threshold = duration.seconds * 0.02
                    if let existing = splitPoints.firstIndex(where: { abs($0.seconds - time.seconds) < threshold }) {
                        splitPoints.remove(at: existing)
                    } else {
                        splitPoints.append(time)
                        splitPoints.sort { $0 < $1 }
                    }
                }

                onSeek(time)
            }
    }

    // MARK: - Thumbnail Generation

    private func generateThumbnails() async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 120)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)

        let durationSeconds = duration.seconds
        guard durationSeconds > 0 else { return }

        var images: [UIImage] = []

        for i in 0..<thumbnailCount {
            let fraction = Double(i) / Double(thumbnailCount)
            let time = CMTime(seconds: fraction * durationSeconds, preferredTimescale: 600)

            if let cgImage = try? await generator.image(at: time).image {
                images.append(UIImage(cgImage: cgImage))
            }
        }

        thumbnails = images
    }
}
