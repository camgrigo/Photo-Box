//
//  VideoExportService.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import Foundation
import AVFoundation
import Photos
import Observation

@Observable
@MainActor
final class VideoExportService {
    var progress: Double = 0.0
    var isExporting = false
    var currentStep = ""

    // MARK: - Trim

    func trimVideo(asset: AVAsset, timeRange: CMTimeRange, deleteOriginal: PHAsset?) async throws {
        isExporting = true
        progress = 0.0
        currentStep = "Trimming\u{2026}"
        defer { isExporting = false }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.cannotCreateSession
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.timeRange = timeRange

        // Monitor progress
        let progressTask = Task.detached { [weak exportSession] in
            while let session = exportSession, session.status == .exporting || session.status == .waiting {
                await MainActor.run { self.progress = Double(session.progress) * 0.8 }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        await exportSession.export()
        progressTask.cancel()

        guard exportSession.status == .completed else {
            throw exportSession.error ?? ExportError.exportFailed
        }

        progress = 0.8
        currentStep = "Saving to library\u{2026}"

        try await saveToPhotosLibrary(url: outputURL)

        if let original = deleteOriginal {
            currentStep = "Removing original\u{2026}"
            try await deleteAsset(original)
        }

        try? FileManager.default.removeItem(at: outputURL)
        progress = 1.0
        currentStep = "Done"
    }

    // MARK: - Split

    func splitVideo(asset: AVAsset, splitPoints: [CMTime], deleteOriginal: PHAsset?) async throws {
        isExporting = true
        progress = 0.0
        defer { isExporting = false }

        let duration = try await asset.load(.duration)

        var boundaries = [CMTime.zero] + splitPoints.sorted { $0 < $1 } + [duration]
        // Remove duplicates and ensure ordering
        boundaries = boundaries.sorted { $0 < $1 }

        let segmentCount = boundaries.count - 1
        var exportedURLs: [URL] = []

        for i in 0..<segmentCount {
            let start = boundaries[i]
            let end = boundaries[i + 1]
            let range = CMTimeRange(start: start, end: end)

            currentStep = "Exporting segment \(i + 1) of \(segmentCount)\u{2026}"

            let composition = AVMutableComposition()
            let tracks = try await asset.loadTracks(withMediaType: .video)

            for track in tracks {
                let compositionTrack = composition.addMutableTrack(
                    withMediaType: track.mediaType,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                try compositionTrack?.insertTimeRange(range, of: track, at: .zero)
            }

            // Also copy audio tracks
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            for track in audioTracks {
                let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                try compositionTrack?.insertTimeRange(range, of: track, at: .zero)
            }

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")

            guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw ExportError.cannotCreateSession
            }

            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mov

            await exportSession.export()

            guard exportSession.status == .completed else {
                throw exportSession.error ?? ExportError.exportFailed
            }

            exportedURLs.append(outputURL)
            progress = Double(i + 1) / Double(segmentCount) * 0.8
        }

        currentStep = "Saving to library\u{2026}"
        for url in exportedURLs {
            try await saveToPhotosLibrary(url: url)
            try? FileManager.default.removeItem(at: url)
        }

        if let original = deleteOriginal {
            currentStep = "Removing original\u{2026}"
            try await deleteAsset(original)
        }

        progress = 1.0
        currentStep = "Done"
    }

    // MARK: - Helpers

    private func saveToPhotosLibrary(url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }

    private func deleteAsset(_ asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSFastEnumeration)
        }
    }

    enum ExportError: LocalizedError {
        case cannotCreateSession
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .cannotCreateSession: "Could not create export session"
            case .exportFailed: "Export failed"
            }
        }
    }
}
