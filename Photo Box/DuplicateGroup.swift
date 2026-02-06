//
//  DuplicateGroup.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import Foundation
import Photos
import SwiftData

struct DuplicateGroup: Identifiable {
    let id: UUID
    let videos: [PHAsset]
    let similarityType: SimilarityType
    let similarityScore: Float

    init(id: UUID = UUID(), videos: [PHAsset], similarityType: SimilarityType, similarityScore: Float) {
        self.id = id
        self.videos = videos
        self.similarityType = similarityType
        self.similarityScore = similarityScore
    }

    enum SimilarityType: String, Codable {
        case exactDuplicate
        case nearDuplicate
        case visuallySimilar
    }
}

@Model
final class PersistedDuplicateGroup {
    var videoIdentifiers: [String]
    var similarityTypeRaw: String
    var similarityScore: Float
    var scanDate: Date

    init(from group: DuplicateGroup) {
        self.videoIdentifiers = group.videos.map(\.localIdentifier)
        self.similarityTypeRaw = group.similarityType.rawValue
        self.similarityScore = group.similarityScore
        self.scanDate = Date()
    }

    var similarityType: DuplicateGroup.SimilarityType {
        DuplicateGroup.SimilarityType(rawValue: similarityTypeRaw) ?? .visuallySimilar
    }

    func toDuplicateGroup() -> DuplicateGroup? {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: videoIdentifiers, options: nil)
        var assets: [PHAsset] = []
        fetchResult.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        guard assets.count > 1 else { return nil }
        return DuplicateGroup(videos: assets, similarityType: similarityType, similarityScore: similarityScore)
    }
}
