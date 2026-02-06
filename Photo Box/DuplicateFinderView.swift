//
//  DuplicateFinderView.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import SwiftUI
import Photos
import SwiftData

struct YearMismatch: Identifiable {
    let id: String // localIdentifier
    let asset: PHAsset
    let metadataYear: Int
    let heuristicYear: Int
}

struct DuplicateFinderView: View {
    let videos: [PHAsset]

    @Environment(\.modelContext) private var modelContext

    // Existing state
    @State private var duplicateGroups: [DuplicateGroup] = []
    @State private var hasScanned = false
    @State private var includeVisualSimilarity = true
    @State private var errorMessage: String?
    @State private var service: DuplicateDetectionService?
    @State private var lastScanDate: Date?
    @State private var yearMismatches: [YearMismatch] = []
    @State private var dateEditAsset: PHAsset?
    @State private var dateEditSuggestedYear: Int?

    // Inline groups state
    @State private var expandedGroups: Set<UUID> = []
    @State private var selections: [UUID: Set<String>] = [:]
    @State private var selectedFilter: SimilarityFilter = .all
    @State private var fileSizeCache: [String: Int64] = [:]
    @State private var showingDeleteConfirmation = false
    @State private var deletingGroupID: UUID?
    @State private var isDeleting = false

    enum SimilarityFilter: String, CaseIterable {
        case all = "All"
        case exact = "Exact"
        case near = "Near"
        case visual = "Visual"
    }

    private var displayedGroups: [DuplicateGroup] {
        if let service, !service.foundGroups.isEmpty {
            return service.foundGroups
        }
        return duplicateGroups
    }

    private var filteredGroups: [DuplicateGroup] {
        let base = displayedGroups
        switch selectedFilter {
        case .all: return base
        case .exact: return base.filter { $0.similarityType == .exactDuplicate }
        case .near: return base.filter { $0.similarityType == .nearDuplicate }
        case .visual: return base.filter { $0.similarityType == .visuallySimilar }
        }
    }

    private var isScanning: Bool {
        service?.isAnalyzing == true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if displayedGroups.isEmpty && yearMismatches.isEmpty {
                    if isScanning {
                        scanningView(service: service!)
                    } else if hasScanned {
                        noResultsView
                    } else {
                        emptyStateView
                    }
                } else {
                    liveResultsView
                }

                if isDeleting {
                    deletingOverlay
                }
            }
            .navigationTitle("Find Duplicates")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if hasScanned, !isScanning {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Rescan") { Task { await performScan() } }
                    }
                }
            }
            .sheet(item: $dateEditAsset) { asset in
                VideoDateEditorView(
                    asset: asset,
                    suggestedYear: dateEditSuggestedYear,
                    yearSource: "heuristic",
                    onDateChanged: {
                        detectYearMismatches()
                    }
                )
            }
            .alert("Delete Videos", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { deletingGroupID = nil }
                Button("Delete", role: .destructive) {
                    if let id = deletingGroupID {
                        Task { await deleteSelected(in: id) }
                    }
                    deletingGroupID = nil
                }
            } message: {
                let count = selections[deletingGroupID ?? UUID()]?.count ?? 0
                Text("Delete \(count) video\(count == 1 ? "" : "s")? They will be moved to Recently Deleted.")
            }
        }
        .task(id: videos.count) {
            loadPersistedResults()
            loadFileSizeCache()
            detectYearMismatches()
            if !hasScanned, !videos.isEmpty, service?.isAnalyzing != true {
                await performScan()
            }
        }
    }

    // MARK: - Views

    private func scanningView(service: DuplicateDetectionService) -> some View {
        VStack(spacing: 24) {
            ProgressView(value: service.progress)
                .tint(.blue)

            Text(service.currentStep)
                .font(.headline)
                .foregroundStyle(.white)

            Text("\(Int(service.progress * 100))%")
                .font(.largeTitle.monospacedDigit())
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding()
    }

    private func scanningBanner(service: DuplicateDetectionService) -> some View {
        VStack(spacing: 8) {
            ProgressView(value: service.progress)
                .tint(.blue)
            HStack {
                Text(service.currentStep)
                    .font(.caption)
                    .foregroundStyle(.gray)
                Spacer()
                Text("\(Int(service.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.gray)
                    .contentTransition(.numericText())
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var noResultsView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("No Duplicates Found")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("Your video library looks clean!")
                .font(.body)
                .foregroundStyle(.gray)

            if !yearMismatches.isEmpty {
                Divider().background(.white.opacity(0.2)).padding(.horizontal, 40)
                Text("\(yearMismatches.count) year mismatch\(yearMismatches.count == 1 ? "" : "es") found")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Find Duplicate Videos")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            Text("Scan your library to find exact duplicates and visually similar videos.")
                .font(.body)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Toggle("Include visual similarity", isOn: $includeVisualSimilarity)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                .padding(.horizontal, 24)

            if !includeVisualSimilarity {
                Text("Only exact metadata matches will be detected.")
                    .font(.caption)
                    .foregroundStyle(.gray.opacity(0.7))
            } else {
                Text("Visual similarity uses AI and takes longer to process.")
                    .font(.caption)
                    .foregroundStyle(.gray.opacity(0.7))
            }
        }
        .padding()
    }

    private var deletingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().tint(.white).scaleEffect(1.5)
                Text("Deleting\u{2026}")
                    .foregroundStyle(.white)
            }
            .padding(40)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    // MARK: - Results

    private var liveResultsView: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let service, service.isAnalyzing {
                    scanningBanner(service: service)
                }

                if !displayedGroups.isEmpty {
                    filterPicker
                }

                summaryCard

                if !yearMismatches.isEmpty {
                    yearMismatchSection
                }

                ForEach(filteredGroups) { group in
                    inlineGroupView(group)
                }
            }
            .padding(24)
            .animation(.snappy, value: selectedFilter)
        }
    }

    private var filterPicker: some View {
        Picker("Filter", selection: $selectedFilter) {
            ForEach(SimilarityFilter.allCases, id: \.self) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
    }

    private var summaryCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("\(filteredGroups.count)")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(filteredGroups.count == 1 ? "Group" : "Groups")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                Spacer()

                let reclaimable = totalReclaimableStorage
                if reclaimable > 0 {
                    VStack {
                        Text(formatByteCount(reclaimable))
                            .font(.title2.bold())
                            .foregroundStyle(.orange)
                        Text("Reclaimable")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                    Spacer()
                }

                VStack(alignment: .trailing) {
                    Text("\(filteredGroups.reduce(0) { $0 + $1.videos.count })")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("Total Videos")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }

            if let lastScanDate, !isScanning {
                Divider().background(.white.opacity(0.2))
                Text("Last scanned \(lastScanDate, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    // MARK: - Inline Group

    private func inlineGroupView(_ group: DuplicateGroup) -> some View {
        let isExpanded = expandedGroups.contains(group.id)
        let selectedCount = selections[group.id]?.count ?? 0

        return VStack(spacing: 0) {
            // Header — tap to expand/collapse
            Button {
                withAnimation(.snappy) {
                    if isExpanded {
                        expandedGroups.remove(group.id)
                    } else {
                        expandedGroups.insert(group.id)
                    }
                }
            } label: {
                inlineGroupHeader(group, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                VStack(spacing: 12) {
                    Text("Tap videos to select, then delete duplicates.")
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(group.videos, id: \.localIdentifier) { asset in
                            DuplicateVideoCard(
                                asset: asset,
                                isSelected: selections[group.id]?.contains(asset.localIdentifier) ?? false,
                                onToggle: { toggleSelection(asset.localIdentifier, in: group.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)

                    if selectedCount > 0 {
                        Button(role: .destructive) {
                            deletingGroupID = group.id
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete \(selectedCount) Selected", systemImage: "trash")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .animation(.snappy, value: isExpanded)
        .animation(.snappy, value: selectedCount)
    }

    private func inlineGroupHeader(_ group: DuplicateGroup, isExpanded: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: groupIcon(group.similarityType))
                .font(.title2)
                .foregroundStyle(groupColor(group.similarityType))

            VStack(alignment: .leading, spacing: 2) {
                Text(groupLabel(group.similarityType))
                    .font(.headline)
                    .foregroundStyle(.white)

                HStack(spacing: 6) {
                    Text("\(group.videos.count) videos")
                        .font(.caption)
                        .foregroundStyle(.gray)

                    if let reclaimable = reclaimableStorage(for: group) {
                        Text("\u{00B7}")
                            .foregroundStyle(.gray)
                        Text(reclaimable)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            if !isExpanded, let firstAsset = group.videos.first {
                GroupThumbnailPreview(asset: firstAsset)
                    .frame(width: 32, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Image(systemName: "chevron.down")
                .font(.caption)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                .foregroundStyle(.gray)
                .animation(.snappy, value: isExpanded)
        }
        .padding(16)
        .contentShape(Rectangle())
    }

    // MARK: - Selection & Delete

    private func toggleSelection(_ assetID: String, in groupID: UUID) {
        var set = selections[groupID] ?? []
        if set.contains(assetID) {
            set.remove(assetID)
        } else {
            set.insert(assetID)
        }
        selections[groupID] = set
    }

    private func deleteSelected(in groupID: UUID) async {
        guard let group = filteredGroups.first(where: { $0.id == groupID }),
              let selected = selections[groupID], !selected.isEmpty else { return }

        isDeleting = true
        defer { isDeleting = false }

        let toDelete = group.videos.filter { selected.contains($0.localIdentifier) }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSFastEnumeration)
            }

            // Clean up SwiftData cache entries
            for asset in toDelete {
                let id = asset.localIdentifier
                let descriptor = FetchDescriptor<VideoAnalysisCache>(
                    predicate: #Predicate { $0.localIdentifier == id }
                )
                if let cached = try? modelContext.fetch(descriptor).first {
                    modelContext.delete(cached)
                }
            }
            try? modelContext.save()

            // Clear selection
            selections[groupID] = nil

            // Update groups — remove deleted assets, drop groups with <2 remaining
            duplicateGroups = duplicateGroups.compactMap { g in
                guard g.id == groupID else { return g }
                let remaining = g.videos.filter { !selected.contains($0.localIdentifier) }
                return remaining.count > 1
                    ? DuplicateGroup(id: g.id, videos: remaining, similarityType: g.similarityType, similarityScore: g.similarityScore)
                    : nil
            }

            if let service {
                service.foundGroups = service.foundGroups.compactMap { g in
                    guard g.id == groupID else { return g }
                    let remaining = g.videos.filter { !selected.contains($0.localIdentifier) }
                    return remaining.count > 1
                        ? DuplicateGroup(id: g.id, videos: remaining, similarityType: g.similarityType, similarityScore: g.similarityScore)
                        : nil
                }
            }

            // Collapse if fully deleted
            if !filteredGroups.contains(where: { $0.id == groupID }) {
                expandedGroups.remove(groupID)
            }

            loadFileSizeCache()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Storage Helpers

    private func loadFileSizeCache() {
        let descriptor = FetchDescriptor<VideoAnalysisCache>()
        guard let all = try? modelContext.fetch(descriptor) else { return }
        fileSizeCache = Dictionary(uniqueKeysWithValues: all.map { ($0.localIdentifier, $0.fileSize) })
    }

    private func reclaimableStorage(for group: DuplicateGroup) -> String? {
        let sizes = group.videos.compactMap { fileSizeCache[$0.localIdentifier] }
        guard sizes.count > 1, let maxSize = sizes.max() else { return nil }
        let reclaimable = sizes.reduce(0, +) - maxSize
        guard reclaimable > 0 else { return nil }
        return "\(formatByteCount(reclaimable)) reclaimable"
    }

    private var totalReclaimableStorage: Int64 {
        var total: Int64 = 0
        for group in filteredGroups {
            let sizes = group.videos.compactMap { fileSizeCache[$0.localIdentifier] }
            guard sizes.count > 1, let maxSize = sizes.max() else { continue }
            total += sizes.reduce(0, +) - maxSize
        }
        return total
    }

    private func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Year Mismatches

    private var yearMismatchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text("Year Mismatches")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("\(yearMismatches.count) video\(yearMismatches.count == 1 ? "" : "s") may have incorrect dates")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                Spacer()
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))

            ForEach(yearMismatches) { mismatch in
                yearMismatchCard(mismatch)
            }
        }
    }

    private func yearMismatchCard(_ mismatch: YearMismatch) -> some View {
        Button {
            dateEditSuggestedYear = mismatch.heuristicYear
            dateEditAsset = mismatch.asset
        } label: {
            HStack(spacing: 16) {
                MismatchThumbnail(asset: mismatch.asset)
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 4) {
                    if let date = mismatch.asset.creationDate {
                        Text(date, format: .dateTime.month().day().year())
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                    Text("\(mismatch.asset.pixelWidth)\u{00D7}\(mismatch.asset.pixelHeight) \u{00B7} \(formatDuration(mismatch.asset.duration))")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }

                Spacer()

                VStack(spacing: 2) {
                    Text("~\(String(mismatch.heuristicYear))")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                    Text("suggested")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.orange, in: RoundedRectangle(cornerRadius: 8))

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                dateEditSuggestedYear = mismatch.heuristicYear
                dateEditAsset = mismatch.asset
            } label: {
                Label("Change Date", systemImage: "calendar")
            }
            Button {
                toggleFavorite(mismatch.asset)
            } label: {
                Label(mismatch.asset.isFavorite ? "Unfavorite" : "Favorite", systemImage: mismatch.asset.isFavorite ? "heart.slash" : "heart")
            }
            Divider()
            Button(role: .destructive) {
                deleteVideo(mismatch.asset)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Helpers

    private func groupIcon(_ type: DuplicateGroup.SimilarityType) -> String {
        switch type {
        case .exactDuplicate: "equal.circle.fill"
        case .nearDuplicate: "doc.on.doc.fill"
        case .visuallySimilar: "eye.circle.fill"
        }
    }

    private func groupColor(_ type: DuplicateGroup.SimilarityType) -> Color {
        switch type {
        case .exactDuplicate: .blue
        case .nearDuplicate: .orange
        case .visuallySimilar: .purple
        }
    }

    private func groupLabel(_ type: DuplicateGroup.SimilarityType) -> String {
        switch type {
        case .exactDuplicate: "Exact Duplicates"
        case .nearDuplicate: "Near Duplicates"
        case .visuallySimilar: "Visually Similar"
        }
    }

    // MARK: - Year Mismatch Detection

    private func detectYearMismatches() {
        let descriptor = FetchDescriptor<VideoAnalysisCache>()
        guard let cache = try? modelContext.fetch(descriptor) else { return }

        let cacheMap = Dictionary(uniqueKeysWithValues: cache.compactMap { item -> (String, VideoAnalysisCache)? in
            (item.localIdentifier, item)
        })

        var mismatches: [YearMismatch] = []
        for asset in videos {
            guard let cached = cacheMap[asset.localIdentifier],
                  let metadataYear = cached.estimatedYear,
                  cached.yearSource == "metadata",
                  let heuristicYear = cached.heuristicYear,
                  abs(metadataYear - heuristicYear) >= 5 else { continue }

            mismatches.append(YearMismatch(
                id: asset.localIdentifier,
                asset: asset,
                metadataYear: metadataYear,
                heuristicYear: heuristicYear
            ))
        }

        yearMismatches = mismatches
    }

    // MARK: - Video Actions

    private func toggleFavorite(_ asset: PHAsset) {
        Task {
            try? await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest(for: asset)
                request.isFavorite = !asset.isFavorite
            }
        }
    }

    private func deleteVideo(_ asset: PHAsset) {
        Task {
            try? await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSFastEnumeration)
            }
            detectYearMismatches()
        }
    }

    // MARK: - Scan Actions

    private func performScan() async {
        let svc = DuplicateDetectionService(modelContext: modelContext)
        service = svc

        do {
            let results = try await svc.detectDuplicates(in: videos, includeVisualSimilarity: includeVisualSimilarity)
            duplicateGroups = results
        } catch {
            errorMessage = error.localizedDescription
        }

        hasScanned = true
        persistResults(duplicateGroups)
        loadFileSizeCache()
        detectYearMismatches()
    }

    // MARK: - Persistence

    private func loadPersistedResults() {
        guard !hasScanned else { return }

        let descriptor = FetchDescriptor<PersistedDuplicateGroup>(
            sortBy: [SortDescriptor(\.scanDate, order: .reverse)]
        )
        guard let persisted = try? modelContext.fetch(descriptor), !persisted.isEmpty else { return }

        lastScanDate = persisted.first?.scanDate
        duplicateGroups = persisted.compactMap { $0.toDuplicateGroup() }
        hasScanned = true
    }

    private func persistResults(_ groups: [DuplicateGroup]) {
        let descriptor = FetchDescriptor<PersistedDuplicateGroup>()
        if let old = try? modelContext.fetch(descriptor) {
            for item in old { modelContext.delete(item) }
        }

        let now = Date()
        for group in groups {
            let persisted = PersistedDuplicateGroup(from: group)
            persisted.scanDate = now
            modelContext.insert(persisted)
        }

        lastScanDate = now
        try? modelContext.save()
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Group Thumbnail Preview

private struct GroupThumbnailPreview: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.gray.opacity(0.3))
            }
        }
        .task {
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 64, height: 96),
                contentMode: .aspectFill,
                options: options
            ) { img, _ in image = img }
        }
    }
}

// MARK: - Mismatch Thumbnail

private struct MismatchThumbnail: View {
    let asset: PHAsset
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.gray.opacity(0.3))
            }
        }
        .task {
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 100, height: 100),
                contentMode: .aspectFill,
                options: nil
            ) { img, _ in
                image = img
            }
        }
    }
}
