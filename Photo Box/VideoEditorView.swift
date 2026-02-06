//
//  VideoEditorView.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import SwiftUI
import AVKit
import AVFoundation
import Photos
import CoreMedia

struct VideoEditorView: View {
    let phAsset: PHAsset

    @Environment(\.dismiss) private var dismiss

    @State private var avAsset: AVAsset?
    @State private var player: AVPlayer?
    @State private var duration: CMTime = .zero
    @State private var isLoading = true

    @State private var editMode: VideoTimelineView.EditMode = .trim
    @State private var trimStart: CMTime = .zero
    @State private var trimEnd: CMTime = .zero
    @State private var splitPoints: [CMTime] = []
    @State private var playheadPosition: CMTime = .zero
    @State private var timeObserver: Any?

    @State private var deleteOriginal = false
    @State private var exportService = VideoExportService()
    @State private var errorMessage: String?
    @State private var showSuccess = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if isLoading {
                    ProgressView("Loading video\u{2026}")
                        .tint(.white)
                        .foregroundStyle(.white)
                } else if let player, let avAsset {
                    editorContent(player: player, avAsset: avAsset)
                }

                if exportService.isExporting {
                    exportOverlay
                }
            }
            .navigationTitle("Edit Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(exportService.isExporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { Task { await performExport() } }
                        .disabled(exportService.isExporting || !canExport)
                }
            }
            .alert("Error", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("Exported", isPresented: $showSuccess) {
                Button("Done") { dismiss() }
            } message: {
                Text(editMode == .trim
                     ? "Trimmed video saved to your library."
                     : "\(splitPoints.count + 1) clips saved to your library.")
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await loadAsset()
        }
        .onDisappear {
            if let timeObserver, let player {
                player.removeTimeObserver(timeObserver)
            }
            player?.pause()
        }
    }

    private var canExport: Bool {
        if editMode == .trim {
            return trimEnd.seconds - trimStart.seconds > 0.1
        } else {
            return !splitPoints.isEmpty
        }
    }

    // MARK: - Editor Content

    private func editorContent(player: AVPlayer, avAsset: AVAsset) -> some View {
        VStack(spacing: 24) {
            // Video preview
            VideoPlayer(player: player)
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // Time display
            timeDisplay

            // Mode picker
            Picker("Mode", selection: $editMode) {
                Text("Trim").tag(VideoTimelineView.EditMode.trim)
                Text("Split").tag(VideoTimelineView.EditMode.split)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            // Timeline
            VideoTimelineView(
                asset: avAsset,
                duration: duration,
                trimStart: $trimStart,
                trimEnd: $trimEnd,
                splitPoints: $splitPoints,
                playheadPosition: $playheadPosition,
                mode: editMode,
                onSeek: { time in
                    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            )
            .padding(.horizontal)

            // Options
            Toggle("Delete original after export", isOn: $deleteOriginal)
                .font(.caption)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
                .padding(.horizontal)

            if editMode == .split {
                Text("Tap the timeline to add split points. Tap a marker to remove it.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                Text("Drag the yellow handles to set trim range.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }

            Spacer()
        }
        .padding(.top)
    }

    private var timeDisplay: some View {
        HStack {
            if editMode == .trim {
                VStack(alignment: .leading) {
                    Text("Start: \(formatTime(trimStart))")
                    Text("End: \(formatTime(trimEnd))")
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Duration")
                        .foregroundStyle(.gray)
                    Text(formatTime(CMTime(seconds: trimEnd.seconds - trimStart.seconds, preferredTimescale: 600)))
                        .fontWeight(.semibold)
                }
            } else {
                Text("\(splitPoints.count) split point\(splitPoints.count == 1 ? "" : "s")")
                Spacer()
                Text("\(splitPoints.count + 1) segments")
                    .foregroundStyle(.gray)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal)
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView(value: exportService.progress)
                    .tint(.blue)
                Text(exportService.currentStep)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\(Int(exportService.progress * 100))%")
                    .font(.largeTitle.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .padding(40)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    // MARK: - Actions

    private func loadAsset() async {
        do {
            let loaded = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVAsset, Error>) in
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = true
                options.deliveryMode = .highQualityFormat

                PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { asset, _, _ in
                    if let asset {
                        continuation.resume(returning: asset)
                    } else {
                        continuation.resume(throwing: VideoExportService.ExportError.exportFailed)
                    }
                }
            }

            let dur = try await loaded.load(.duration)
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: loaded))

            avAsset = loaded
            duration = dur
            trimEnd = dur
            player = newPlayer
            isLoading = false

            // Observe playhead
            let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
            timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                playheadPosition = time
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func performExport() async {
        guard let avAsset else { return }

        let originalToDelete: PHAsset? = deleteOriginal ? phAsset : nil

        do {
            if editMode == .trim {
                let range = CMTimeRange(start: trimStart, end: trimEnd)
                try await exportService.trimVideo(asset: avAsset, timeRange: range, deleteOriginal: originalToDelete)
            } else {
                try await exportService.splitVideo(asset: avAsset, splitPoints: splitPoints, deleteOriginal: originalToDelete)
            }
            showSuccess = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatTime(_ time: CMTime) -> String {
        let totalSeconds = Int(time.seconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let fraction = Int((time.seconds - Double(totalSeconds)) * 10)
        return String(format: "%d:%02d.%d", minutes, seconds, fraction)
    }
}
