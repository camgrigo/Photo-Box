//
//  Photo_BoxApp.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import SwiftUI
import SwiftData

@main
struct Photo_BoxApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            VideoItem.self,
            VideoAnalysisCache.self,
            PersistedDuplicateGroup.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)

        WindowGroup("Video Player", id: "video-player", for: String.self) { $localIdentifier in
            if let localIdentifier {
                VideoPlayerWindow(localIdentifier: localIdentifier)
            }
        }
        .modelContainer(sharedModelContainer)
    }
}
