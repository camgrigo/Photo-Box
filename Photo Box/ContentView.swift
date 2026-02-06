//
//  ContentView.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import SwiftUI
import SwiftData
import Photos
import PhotosUI
import AVKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var photoLibraryVideos: [PHAsset] = []
    @State private var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @State private var showingVideoPicker = false
    @State private var groupByYear = false
    @State private var showFavoritesOnly = false
    @State private var yearTagger = YearTaggingService()
    @State private var yearGroups: [(year: Int, assets: [PHAsset])] = []
    @State private var dateEditAsset: PHAsset?
    @State private var dateEditSuggestedYear: Int?
    @State private var dateEditYearSource: String?
    @Namespace private var namespace
    
    // Larger cards for Mac
    let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 20)
    ]

    private var displayedVideos: [PHAsset] {
        showFavoritesOnly ? photoLibraryVideos.filter(\.isFavorite) : photoLibraryVideos
    }
    
    var body: some View {
        TabView {
            Tab("Library", systemImage: "film.stack") {
                libraryTab
            }
            Tab("Duplicates", systemImage: "doc.on.doc") {
                DuplicateFinderView(videos: photoLibraryVideos)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await checkPhotoLibraryAuthorization()
        }
    }

    private var libraryTab: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if authorizationStatus == .authorized || authorizationStatus == .limited {
                    if photoLibraryVideos.isEmpty {
                        emptyStateView
                    } else if groupByYear {
                        yearGroupedView
                    } else {
                        videoGridView
                    }
                } else {
                    permissionRequestView
                }
            }
            .navigationTitle("Video Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if !photoLibraryVideos.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            groupByYear.toggle()
                            if groupByYear { buildYearGroups() }
                        } label: {
                            Label(
                                groupByYear ? "All Videos" : "By Year",
                                systemImage: groupByYear ? "square.grid.2x2" : "calendar"
                            )
                            .foregroundStyle(.white)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFavoritesOnly.toggle()
                    } label: {
                        Label(
                            showFavoritesOnly ? "All" : "Favorites",
                            systemImage: showFavoritesOnly ? "heart.fill" : "heart"
                        )
                        .foregroundStyle(showFavoritesOnly ? .red : .white)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        loadVideos()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .foregroundStyle(.white)
                    }
                }
            }
            .sheet(item: $dateEditAsset) { asset in
                VideoDateEditorView(
                    asset: asset,
                    suggestedYear: dateEditSuggestedYear,
                    yearSource: dateEditYearSource,
                    onDateChanged: {
                        loadVideos()
                        Task { await yearTagger.tagVideos(assets: photoLibraryVideos, modelContext: modelContext) }
                        if groupByYear { buildYearGroups() }
                    }
                )
            }
        }
    }
    
    private var videoCountHeader: some View {
        Text("\(displayedVideos.count) videos")
            .font(.subheadline)
            .foregroundStyle(.gray)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
    }

    private var videoGridView: some View {
        ScrollView {
            videoCountHeader

            GlassEffectContainer(spacing: 30.0) {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(displayedVideos, id: \.localIdentifier) { asset in
                        videoCard(for: asset)
                    }
                }
            }
            .padding(24)
        }
    }

    private var yearGroupedView: some View {
        ScrollView {
            videoCountHeader

            GlassEffectContainer(spacing: 30.0) {
                LazyVStack(alignment: .leading, spacing: 32) {
                    ForEach(yearGroups, id: \.year) { group in
                        let filtered = showFavoritesOnly ? group.assets.filter(\.isFavorite) : group.assets
                        if !filtered.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text(String(group.year))
                                        .font(.title.bold())
                                        .foregroundStyle(.white)
                                    Text("\(filtered.count) videos")
                                        .font(.caption)
                                        .foregroundStyle(.gray)
                                }

                                LazyVGrid(columns: columns, spacing: 20) {
                                    ForEach(filtered, id: \.localIdentifier) { asset in
                                        videoCard(for: asset)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .padding(.top, 8)
        }
    }

    private func videoCard(for asset: PHAsset) -> some View {
        NavigationLink {
            VideoPlayerView(asset: asset)
                .navigationTransition(.zoom(sourceID: asset.localIdentifier, in: namespace))
        } label: {
            MoviePosterCard(asset: asset)
                .glassEffectID(asset.localIdentifier, in: namespace)
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: asset.localIdentifier, in: namespace)
        .contextMenu {
            Button {
                toggleFavorite(asset)
            } label: {
                Label(asset.isFavorite ? "Unfavorite" : "Favorite", systemImage: asset.isFavorite ? "heart.slash" : "heart")
            }
            Button {
                openDateEditor(for: asset)
            } label: {
                Label("Change Date", systemImage: "calendar")
            }
            Divider()
            Button(role: .destructive) {
                deleteVideo(asset)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "film.stack")
                .font(.system(size: 70))
                .foregroundStyle(.gray)
            Text("No Videos Found")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("Your video library is empty")
                .font(.body)
                .foregroundStyle(.gray)
        }
    }
    
    private var permissionRequestView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 70))
                .foregroundStyle(.blue)
            Text("Photo Library Access")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("Allow access to view your videos")
                .font(.body)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
            
            Button("Grant Access") {
                Task {
                    await requestPhotoLibraryAuthorization()
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding()
    }
    
    private func checkPhotoLibraryAuthorization() async {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

        if authorizationStatus == .authorized || authorizationStatus == .limited {
            loadVideos()
            await yearTagger.tagVideos(assets: photoLibraryVideos, modelContext: modelContext)
        }
    }
    
    private func requestPhotoLibraryAuthorization() async {
        authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            loadVideos()
        }
    }
    
    private func loadVideos() {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        
        let results = PHAsset.fetchAssets(with: .video, options: fetchOptions)
        
        var videos: [PHAsset] = []
        results.enumerateObjects { asset, _, _ in
            videos.append(asset)
        }
        
        photoLibraryVideos = videos
    }

    private func buildYearGroups() {
        let descriptor = FetchDescriptor<VideoAnalysisCache>()
        guard let cache = try? modelContext.fetch(descriptor) else { return }

        let cacheMap = Dictionary(uniqueKeysWithValues: cache.compactMap { item -> (String, VideoAnalysisCache)? in
            (item.localIdentifier, item)
        })

        var grouped: [Int: [PHAsset]] = [:]
        for asset in displayedVideos {
            let year = cacheMap[asset.localIdentifier]?.estimatedYear
                ?? asset.creationDate.map { Calendar.current.component(.year, from: $0) }
                ?? 0
            grouped[year, default: []].append(asset)
        }

        yearGroups = grouped.sorted { $0.key > $1.key }
            .map { (year: $0.key, assets: $0.value) }
    }

    private func deleteVideo(_ asset: PHAsset) {
        Task {
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSFastEnumeration)
            }
            loadVideos()
            if groupByYear { buildYearGroups() }
        }
    }

    private func toggleFavorite(_ asset: PHAsset) {
        Task {
            try? await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest(for: asset)
                request.isFavorite = !asset.isFavorite
            }
            loadVideos()
        }
    }

    private func openDateEditor(for asset: PHAsset) {
        let id = asset.localIdentifier
        let descriptor = FetchDescriptor<VideoAnalysisCache>(predicate: #Predicate { $0.localIdentifier == id })
        let cached = try? modelContext.fetch(descriptor).first
        dateEditSuggestedYear = cached?.estimatedYear
        dateEditYearSource = cached?.yearSource
        dateEditAsset = asset
    }
}

// MARK: - Movie Poster Card
struct MoviePosterCard: View {
    let asset: PHAsset
    @State private var thumbnail: UIImage?
    @State private var isHovering = false
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Poster Image
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
            } else {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .aspectRatio(2/3, contentMode: .fit)
                    .overlay {
                        ProgressView()
                            .tint(.white)
                    }
            }

            // Favorite badge (top-right)
            if asset.isFavorite {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(6)
                            .glassEffect(.regular, in: .circle)
                    }
                    Spacer()
                }
                .padding(6)
            }

            // Gradient overlay
            LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .center,
                endPoint: .bottom
            )

            // Duration badge with Liquid Glass
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "play.circle.fill")
                        .font(.caption)
                    Text(formatDuration(asset.duration))
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 6))

                if let creationDate = asset.creationDate {
                    Text(creationDate, format: .dateTime.month().day().year())
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
        .scaleEffect(isHovering ? 1.05 : 1.0)
        .animation(.smooth(duration: 0.3), value: isHovering)
        #if targetEnvironment(macCatalyst)
        .onHover { hovering in
            isHovering = hovering
        }
        .help("Click to play video")
        #endif
        .task {
            await loadThumbnail()
        }
    }
    
    private func loadThumbnail() async {
        let imageManager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        // Higher resolution for Mac displays
        #if targetEnvironment(macCatalyst)
        let targetSize = CGSize(width: 600, height: 900)
        #else
        let targetSize = CGSize(width: 400, height: 600)
        #endif
        
        imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            thumbnail = image
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Video Player View
struct VideoPlayerView: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var showingEditor = false
    @State private var isFavorite: Bool

    init(asset: PHAsset) {
        self.asset = asset
        _isFavorite = State(initialValue: asset.isFavorite)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                    Text("Loading video...")
                        .foregroundStyle(.white.opacity(0.7))
                        .font(.caption)
                }
            }
        }
        .navigationTitle(asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Video")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        try? await PHPhotoLibrary.shared().performChanges {
                            let request = PHAssetChangeRequest(for: asset)
                            request.isFavorite = !isFavorite
                        }
                        isFavorite.toggle()
                    }
                } label: {
                    Label("Favorite", systemImage: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? .red : .white)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    player?.pause()
                    showingEditor = true
                } label: {
                    Label("Edit", systemImage: "scissors")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    player?.pause()
                    dismiss()
                }
            }
        }
        .fullScreenCover(isPresented: $showingEditor) {
            VideoEditorView(phAsset: asset)
        }
        .task {
            await loadVideo()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
    
    private func loadVideo() async {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
            if let playerItem = playerItem {
                DispatchQueue.main.async {
                    self.player = AVPlayer(playerItem: playerItem)
                    self.isLoading = false
                    self.player?.play()
                }
            }
        }
    }
}

// Extension to make PHAsset identifiable
extension PHAsset: @retroactive Identifiable {
    public var id: String { localIdentifier }
}

#Preview {
    ContentView()
        .modelContainer(for: VideoItem.self, inMemory: true)
}
