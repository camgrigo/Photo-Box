//
//  ThumbnailCache.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/7/26.
//

import Photos
import SwiftUI

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, PlatformImage>()
    private var inFlight: [String: [(PlatformImage) -> Void]] = [:]

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 100 * 1024 * 1024 // ~100 MB
    }

    func thumbnail(for asset: PHAsset, size: CGSize) -> PlatformImage? {
        let key = cacheKey(asset.localIdentifier, size: size)
        return cache.object(forKey: key as NSString)
    }

    func loadThumbnail(
        for asset: PHAsset,
        size: CGSize,
        mode: PHImageContentMode = .aspectFill,
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic,
        completion: @escaping (PlatformImage) -> Void
    ) {
        let key = cacheKey(asset.localIdentifier, size: size)

        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return
        }

        // Coalesce duplicate requests
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            return
        }
        inFlight[key] = [completion]

        let options = PHImageRequestOptions()
        options.deliveryMode = deliveryMode
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: size,
            contentMode: mode,
            options: options
        ) { [weak self] image, info in
            guard let self, let image else { return }
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false

            let cost = estimateCost(image)
            self.cache.setObject(image, forKey: key as NSString, cost: cost)

            if let callbacks = self.inFlight[key] {
                for cb in callbacks { cb(image) }
            }
            // Only remove in-flight once we have the full-quality version
            if !isDegraded {
                self.inFlight.removeValue(forKey: key)
            }
        }
    }

    private func cacheKey(_ identifier: String, size: CGSize) -> String {
        "\(identifier)_\(Int(size.width))x\(Int(size.height))"
    }

    private func estimateCost(_ image: PlatformImage) -> Int {
        #if canImport(UIKit)
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
        #else
        guard let rep = image.representations.first else { return 0 }
        return rep.pixelsWide * rep.pixelsHigh * 4
        #endif
    }
}
