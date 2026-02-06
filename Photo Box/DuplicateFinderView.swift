//
//  DuplicateFinderView.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import SwiftUI
import Photos
import SwiftData

struct DuplicateFinderView: View {
    let videos: [PHAsset]

    @Environment(\.modelContext) private var modelContext

    @State private var duplicateGroups: [DuplicateGroup] = []
    @State private var hasScanned = false
    @State private var includeVisualSimilarity = true
    @State private var errorMessage: String?
    @State private var service: DuplicateDetectionService?
    @State private var lastScanDate: Date?

    private var displayedGroups: [DuplicateGroup] {
        if let service, !service.foundGroups.isEmpty {
            return service.foundGroups
        }
        return duplicateGroups
    }

    private var isScanning: Bool {
        service?.isAnalyzing == true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if displayedGroups.isEmpty {
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
        }
        .task(id: videos.count) {
            loadPersistedResults()
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

    private var liveResultsView: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let service, service.isAnalyzing {
                    scanningBanner(service: service)
                }

                summaryCard

                ForEach(displayedGroups) { group in
                    NavigationLink {
                        DuplicateGroupDetailView(group: group)
                    } label: {
                        groupCard(group)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
        }
    }

    private var summaryCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("\(displayedGroups.count)")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(displayedGroups.count == 1 ? "Group" : "Groups")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("\(displayedGroups.reduce(0) { $0 + $1.videos.count })")
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

    private func groupCard(_ group: DuplicateGroup) -> some View {
        HStack(spacing: 16) {
            Image(systemName: groupIcon(group.similarityType))
                .font(.title2)
                .foregroundStyle(groupColor(group.similarityType))

            VStack(alignment: .leading, spacing: 4) {
                Text(groupLabel(group.similarityType))
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("\(group.videos.count) videos \u{00B7} \(formatDuration(group.videos.first?.duration ?? 0))")
                    .font(.caption)
                    .foregroundStyle(.gray)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.gray)
        }
        .padding(16)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
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

    // MARK: - Actions

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
        // Delete old results
        let descriptor = FetchDescriptor<PersistedDuplicateGroup>()
        if let old = try? modelContext.fetch(descriptor) {
            for item in old { modelContext.delete(item) }
        }

        // Insert new results
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
