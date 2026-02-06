//
//  VideoAnalysisCache.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import Foundation
import SwiftData

@Model
final class VideoAnalysisCache {
    @Attribute(.unique) var localIdentifier: String
    var duration: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSize: Int64
    var featurePrintData: Data?
    var estimatedYear: Int?
    var yearSource: String?
    var heuristicYear: Int?
    var lastAnalyzed: Date
    var analysisVersion: Int

    init(localIdentifier: String, duration: Double, pixelWidth: Int, pixelHeight: Int, fileSize: Int64, featurePrintData: Data? = nil) {
        self.localIdentifier = localIdentifier
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileSize = fileSize
        self.featurePrintData = featurePrintData
        self.lastAnalyzed = Date()
        self.analysisVersion = 1
    }
}
