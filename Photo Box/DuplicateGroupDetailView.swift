//
//  DuplicateGroupDetailView.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import SwiftUI
import Photos
import SwiftData

struct DuplicateGroupDetailView: View {
    let group: DuplicateGroup

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedForDeletion = Set<String>()
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerCard

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)], spacing: 16) {
                    ForEach(group.videos, id: \.localIdentifier) { asset in
                        DuplicateVideoCard(
                            asset: asset,
                            isSelected: selectedForDeletion.contains(asset.localIdentifier),
                            onToggle: { toggleSelection(asset.localIdentifier) }
                        )
                    }
                }
            }
            .padding(24)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Duplicate Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Delete Selected (\(selectedForDeletion.count))") {
                    showingDeleteConfirmation = true
                }
                .disabled(selectedForDeletion.isEmpty || isDeleting)
            }
        }
        .alert("Delete Videos", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await deleteSelected() }
            }
        } message: {
            Text("Delete \(selectedForDeletion.count) video(s)? They will be moved to Recently Deleted.")
        }
        .alert("Error", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay {
            if isDeleting {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView().tint(.white).scaleEffect(1.5)
                        Text("Deleting\u{2026}").foregroundStyle(.white)
                    }
                    .padding(40)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: group.similarityType == .exactDuplicate ? "equal.circle.fill" : "eye.circle.fill")
                    .font(.title2)
                    .foregroundStyle(group.similarityType == .exactDuplicate ? .blue : .purple)
                VStack(alignment: .leading) {
                    Text(group.similarityType == .exactDuplicate ? "Exact Duplicates" : "Visually Similar")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("\(group.videos.count) videos")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                Spacer()
            }

            Divider().background(.white.opacity(0.2))

            Text("Tap videos to select them for deletion. Consider keeping the oldest or highest quality version.")
                .font(.caption)
                .foregroundStyle(.gray)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func toggleSelection(_ id: String) {
        if selectedForDeletion.contains(id) {
            selectedForDeletion.remove(id)
        } else {
            selectedForDeletion.insert(id)
        }
    }

    private func deleteSelected() async {
        isDeleting = true
        defer { isDeleting = false }

        let toDelete = group.videos.filter { selectedForDeletion.contains($0.localIdentifier) }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(toDelete as NSFastEnumeration)
            }

            // Clean up cache entries
            for asset in toDelete {
                let id = asset.localIdentifier
                let descriptor = FetchDescriptor<VideoAnalysisCache>(predicate: #Predicate { $0.localIdentifier == id })
                if let cached = try? modelContext.fetch(descriptor).first {
                    modelContext.delete(cached)
                }
            }
            try? modelContext.save()

            if toDelete.count >= group.videos.count {
                dismiss()
            } else {
                selectedForDeletion.removeAll()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
