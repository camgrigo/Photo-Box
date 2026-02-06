//
//  YearTaggingService.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import Foundation
import Photos
import SwiftData
import Observation

@Observable
@MainActor
final class YearTaggingService {
    var isTagging = false
    var taggedCount = 0
    var totalCount = 0

    func tagVideos(assets: [PHAsset], modelContext: ModelContext) async {
        isTagging = true
        totalCount = assets.count
        taggedCount = 0
        defer { isTagging = false }

        // Load existing cache
        var cache: [String: VideoAnalysisCache] = [:]
        if let existing = try? modelContext.fetch(FetchDescriptor<VideoAnalysisCache>()) {
            for item in existing {
                cache[item.localIdentifier] = item
            }
        }

        for asset in assets {
            let id = asset.localIdentifier
            let heuristic = estimateYearFromHeuristics(asset: asset)

            if let cached = cache[id] {
                // Always store the heuristic year
                if cached.heuristicYear == nil {
                    cached.heuristicYear = heuristic
                }

                if cached.estimatedYear != nil {
                    taggedCount += 1
                    continue
                }
            }

            let year: Int
            let source: String

            if let date = asset.creationDate {
                year = Calendar.current.component(.year, from: date)
                source = "metadata"
            } else {
                year = heuristic
                source = "heuristic"
            }

            if let cached = cache[id] {
                cached.estimatedYear = year
                cached.yearSource = source
                cached.heuristicYear = heuristic
            } else {
                let item = VideoAnalysisCache(
                    localIdentifier: id,
                    duration: asset.duration,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    fileSize: 0
                )
                item.estimatedYear = year
                item.yearSource = source
                item.heuristicYear = heuristic
                modelContext.insert(item)
            }

            taggedCount += 1
        }

        try? modelContext.save()
    }

    // MARK: - Heuristics

    private func estimateYearFromHeuristics(asset: PHAsset) -> Int {
        let w = asset.pixelWidth
        let h = asset.pixelHeight
        let maxDim = max(w, h)
        let minDim = min(w, h)

        let isVertical = h > w
        let aspectRatio = Double(maxDim) / Double(max(minDim, 1))
        let isFourByThree = aspectRatio < 1.5

        // Vertical video is a strong smartphone-era signal
        if isVertical && maxDim >= 1080 {
            return 2016
        }

        if isFourByThree {
            // 4:3 aspect ratio — older camcorder/webcam era
            if maxDim <= 480 { return 2005 }
            if maxDim <= 720 { return 2008 }
            return 2010
        }

        // 16:9 widescreen
        if maxDim <= 720 { return 2010 }
        if maxDim <= 1080 { return 2014 }
        if maxDim <= 2160 { return 2018 }
        return 2020
    }
}
