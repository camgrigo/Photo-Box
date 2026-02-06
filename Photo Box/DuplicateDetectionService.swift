//
//  DuplicateDetectionService.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import Foundation
import Photos
import AVFoundation
import Vision
import SwiftData
import Observation

@Observable
@MainActor
final class DuplicateDetectionService {
    var progress: Double = 0.0
    var currentStep: String = ""
    var isAnalyzing: Bool = false
    var foundGroups: [DuplicateGroup] = []

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Public API

    @discardableResult
    func detectDuplicates(in assets: [PHAsset], includeVisualSimilarity: Bool = true) async throws -> [DuplicateGroup] {
        isAnalyzing = true
        progress = 0.0
        foundGroups = []
        defer {
            isAnalyzing = false
            progress = 1.0
        }

        // Step 1: Build metadata cache
        currentStep = "Analyzing metadata\u{2026}"
        let cache = try await buildCache(for: assets)

        // Step 2: Tier 1 — exact duplicates (same resolution, duration ≈, same file size)
        currentStep = "Finding exact duplicates\u{2026}"
        let exactGroups = findExactDuplicates(cache: cache, assets: assets)
        foundGroups.append(contentsOf: exactGroups)
        progress = 0.25

        // Step 3: Tier 1.5 — near duplicates (same resolution, duration within 3s)
        currentStep = "Finding near duplicates\u{2026}"
        let nearGroups = findNearDuplicates(cache: cache, assets: assets, excludeGroups: exactGroups)
        foundGroups.append(contentsOf: nearGroups)
        progress = 0.35

        // Step 4: Tier 2 — visual similarity
        if includeVisualSimilarity {
            let allPriorGroups = exactGroups + nearGroups
            try await findVisuallySimilar(cache: cache, assets: assets, excludeGroups: allPriorGroups)
        }

        currentStep = "Done"
        return foundGroups
    }

    // MARK: - Cache

    private func buildCache(for assets: [PHAsset]) async throws -> [String: VideoAnalysisCache] {
        var cache: [String: VideoAnalysisCache] = [:]

        let descriptor = FetchDescriptor<VideoAnalysisCache>()
        let existing = try modelContext.fetch(descriptor)
        for item in existing {
            cache[item.localIdentifier] = item
        }

        let total = Double(assets.count)
        for (index, asset) in assets.enumerated() {
            progress = Double(index) / total * 0.2

            if cache[asset.localIdentifier] == nil {
                let fileSize = fileSizeForAsset(asset)
                let item = VideoAnalysisCache(
                    localIdentifier: asset.localIdentifier,
                    duration: asset.duration,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    fileSize: fileSize
                )
                modelContext.insert(item)
                cache[asset.localIdentifier] = item
            }
        }

        try modelContext.save()
        return cache
    }

    private func fileSizeForAsset(_ asset: PHAsset) -> Int64 {
        guard let resource = PHAssetResource.assetResources(for: asset).first else { return 0 }
        return resource.value(forKey: "fileSize") as? Int64 ?? 0
    }

    // MARK: - Tier 1: Exact Duplicates

    private func findExactDuplicates(cache: [String: VideoAnalysisCache], assets: [PHAsset]) -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        var processed = Set<String>()

        for asset in assets {
            let id = asset.localIdentifier
            guard !processed.contains(id), let cacheItem = cache[id] else { continue }

            var matches: [PHAsset] = [asset]

            for other in assets {
                let otherId = other.localIdentifier
                guard otherId != id,
                      !processed.contains(otherId),
                      let otherCache = cache[otherId] else { continue }

                if abs(cacheItem.duration - otherCache.duration) < 0.5,
                   cacheItem.pixelWidth == otherCache.pixelWidth,
                   cacheItem.pixelHeight == otherCache.pixelHeight,
                   cacheItem.fileSize == otherCache.fileSize,
                   cacheItem.fileSize > 0 {
                    matches.append(other)
                    processed.insert(otherId)
                }
            }

            if matches.count > 1 {
                groups.append(DuplicateGroup(videos: matches, similarityType: .exactDuplicate, similarityScore: 0.0))
            }
            processed.insert(id)
        }

        return groups
    }

    // MARK: - Tier 1.5: Near Duplicates

    private func findNearDuplicates(cache: [String: VideoAnalysisCache], assets: [PHAsset], excludeGroups: [DuplicateGroup]) -> [DuplicateGroup] {
        let excludedIds = Set(excludeGroups.flatMap { $0.videos.map(\.localIdentifier) })
        let candidates = assets.filter { !excludedIds.contains($0.localIdentifier) }

        var groups: [DuplicateGroup] = []
        var processed = Set<String>()

        for asset in candidates {
            let id = asset.localIdentifier
            guard !processed.contains(id), let cacheItem = cache[id] else { continue }

            var matches: [PHAsset] = [asset]

            for other in candidates {
                let otherId = other.localIdentifier
                guard otherId != id,
                      !processed.contains(otherId),
                      let otherCache = cache[otherId] else { continue }

                // Same resolution, duration within 3 seconds
                if cacheItem.pixelWidth == otherCache.pixelWidth,
                   cacheItem.pixelHeight == otherCache.pixelHeight,
                   abs(cacheItem.duration - otherCache.duration) < 3.0 {
                    matches.append(other)
                    processed.insert(otherId)
                }
            }

            if matches.count > 1 {
                groups.append(DuplicateGroup(videos: matches, similarityType: .nearDuplicate, similarityScore: 0.0))
            }
            processed.insert(id)
        }

        return groups
    }

    // MARK: - Tier 2: Visual Similarity

    private func findVisuallySimilar(
        cache: [String: VideoAnalysisCache],
        assets: [PHAsset],
        excludeGroups: [DuplicateGroup]
    ) async throws {
        let excludedIds = Set(excludeGroups.flatMap { $0.videos.map(\.localIdentifier) })
        let candidates = assets.filter { !excludedIds.contains($0.localIdentifier) }

        // Generate feature prints for candidates that don't have them
        let total = Double(candidates.count)
        for (index, asset) in candidates.enumerated() {
            progress = 0.35 + (Double(index) / total * 0.45)
            currentStep = "Analyzing video \(index + 1) of \(candidates.count)\u{2026}"

            if let cacheItem = cache[asset.localIdentifier], cacheItem.featurePrintData == nil {
                if let data = try await extractFeaturePrintData(for: asset) {
                    cacheItem.featurePrintData = data
                }
            }
        }

        try modelContext.save()

        // Compare feature prints — stream results as found
        currentStep = "Comparing videos\u{2026}"
        var processed = Set<String>()
        let threshold: Float = 30.0

        for asset in candidates {
            let id = asset.localIdentifier
            guard !processed.contains(id),
                  let cacheItem = cache[id],
                  let data = cacheItem.featurePrintData,
                  let featurePrint = deserializeFeaturePrint(data) else { continue }

            var matches: [PHAsset] = [asset]
            var bestScore: Float = 0.0

            for other in candidates {
                let otherId = other.localIdentifier
                guard otherId != id,
                      !processed.contains(otherId),
                      let otherCache = cache[otherId],
                      let otherData = otherCache.featurePrintData,
                      let otherPrint = deserializeFeaturePrint(otherData) else { continue }

                var distance: Float = 0
                try featurePrint.computeDistance(&distance, to: otherPrint)

                if distance < threshold {
                    matches.append(other)
                    processed.insert(otherId)
                    bestScore = max(bestScore, distance)
                }
            }

            if matches.count > 1 {
                foundGroups.append(DuplicateGroup(videos: matches, similarityType: .visuallySimilar, similarityScore: bestScore))
            }
            processed.insert(id)
        }

        progress = 0.95
    }

    // MARK: - Feature Print Extraction

    private func extractFeaturePrintData(for asset: PHAsset) async throws -> Data? {
        let avAsset = try await loadAVAsset(for: asset)
        let duration = try await avAsset.load(.duration)
        let totalSeconds = duration.seconds

        guard totalSeconds > 0 else { return nil }

        let positions = [0.1, 0.25, 0.5, 0.75, 0.9]
        var featurePrints: [VNFeaturePrintObservation] = []

        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)

        for position in positions {
            let time = CMTime(seconds: totalSeconds * position, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(at: time).image else { continue }

            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            if let result = request.results?.first {
                featurePrints.append(result)
            }
        }

        // Use the middle frame as the representative feature print
        guard let representative = featurePrints.count >= 3 ? featurePrints[featurePrints.count / 2] : featurePrints.first else {
            return nil
        }

        return serializeFeaturePrint(representative)
    }

    private func loadAVAsset(for asset: PHAsset) async throws -> AVAsset {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat

            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    continuation.resume(throwing: NSError(domain: "DuplicateDetection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not load video"]))
                }
            }
        }
    }

    // MARK: - Serialization

    private func serializeFeaturePrint(_ observation: VNFeaturePrintObservation) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }

    private func deserializeFeaturePrint(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }
}
