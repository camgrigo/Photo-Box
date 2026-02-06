//
//  VideoDateEditorView.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/5/26.
//

import SwiftUI
import Photos
import SwiftData

struct VideoDateEditorView: View {
    let asset: PHAsset
    let suggestedYear: Int?
    let yearSource: String?
    var onDateChanged: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDate: Date
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(asset: PHAsset, suggestedYear: Int?, yearSource: String?, onDateChanged: (() -> Void)? = nil) {
        self.asset = asset
        self.suggestedYear = suggestedYear
        self.yearSource = yearSource
        self.onDateChanged = onDateChanged
        _selectedDate = State(initialValue: asset.creationDate ?? Date())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        currentDateCard
                        datePickerCard

                        if let suggestedYear, yearSource == "heuristic" {
                            suggestionCard(year: suggestedYear)
                        }
                    }
                    .padding(24)
                }
            }
            .navigationTitle("Change Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { Task { await applyDate(selectedDate) } }
                        .disabled(isSaving)
                }
            }
            .alert("Error", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.5).ignoresSafeArea()
                        ProgressView().tint(.white).scaleEffect(1.5)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var currentDateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current Date")
                .font(.caption)
                .foregroundStyle(.gray)

            if let date = asset.creationDate {
                Text(date, format: .dateTime.month().day().year().hour().minute())
                    .font(.title3.bold())
                    .foregroundStyle(.white)
            } else {
                Text("No date set")
                    .font(.title3.bold())
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var datePickerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Date")
                .font(.caption)
                .foregroundStyle(.gray)

            DatePicker("", selection: $selectedDate, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .tint(.blue)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func suggestionCard(year: Int) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.yellow)
                Text("Suggested Year")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
            }

            Text("Based on resolution and aspect ratio, this video appears to be from around \(String(year)).")
                .font(.caption)
                .foregroundStyle(.gray)

            Button {
                Task {
                    var components = DateComponents()
                    components.year = year
                    components.month = 6
                    components.day = 15
                    if let date = Calendar.current.date(from: components) {
                        await applyDate(date)
                    }
                }
            } label: {
                Label("Use ~\(String(year))", systemImage: "calendar.badge.checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func applyDate(_ date: Date) async {
        isSaving = true
        defer { isSaving = false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest(for: asset)
                request.creationDate = date
            }

            // Update cache
            let id = asset.localIdentifier
            let descriptor = FetchDescriptor<VideoAnalysisCache>(predicate: #Predicate { $0.localIdentifier == id })
            if let cached = try? modelContext.fetch(descriptor).first {
                cached.estimatedYear = Calendar.current.component(.year, from: date)
                cached.yearSource = "metadata"
                try? modelContext.save()
            }

            onDateChanged?()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
