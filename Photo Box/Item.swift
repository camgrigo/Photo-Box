//
//  Item.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import Foundation
import SwiftData
import Photos

@Model
final class VideoItem {
    var id: String
    var dateAdded: Date
    var localIdentifier: String
    
    init(localIdentifier: String) {
        self.id = UUID().uuidString
        self.dateAdded = Date()
        self.localIdentifier = localIdentifier
    }
}
