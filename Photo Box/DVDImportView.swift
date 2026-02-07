//
//  DVDImportView.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/6/26.
//

#if os(macOS)
import SwiftUI

struct DVDImportView: View {
    @State private var service = DVDImportService()
    @State private var selectedTitleIDs: Set<Int> = []
    @State private var hasScanned = false
    @State private var titleNames: [Int: String] = [:]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if service.isDetecting {
                    discSpinUpView
                } else if service.detectedDiscs.isEmpty {
                    noDiscView
                } else if let disc = service.detectedDiscs.first {
                    if service.isScanning {
                        scanningView
                    } else if disc.titles.isEmpty && !hasScanned {
                        discDetectedView(disc)
                    } else if disc.titles.isEmpty && hasScanned {
                        noTitlesView
                    } else {
                        titleListView(disc)
                    }
                }

                if service.isConverting {
                    conversionOverlay
                }
            }
            .navigationTitle("DVD Import")
        }
        .preferredColorScheme(.dark)
        .onAppear {
            service.startObservingDiscs()
        }
        .onDisappear {
            service.stopObservingDiscs()
        }
    }

    // MARK: - Disc Spin-Up

    private var discSpinUpView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.blue)
            Text("Looking for disc\u{2026}")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("The disc drive is spinning up. This may take a few moments.")
                .font(.body)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    // MARK: - No Disc

    private var noDiscView: some View {
        VStack(spacing: 20) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 70))
                .foregroundStyle(.gray)
            Text("No DVD Detected")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("Insert a DVD to get started")
                .font(.body)
                .foregroundStyle(.gray)

            Button {
                service.detectDVDs()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    // MARK: - Disc Detected

    private func discDetectedView(_ disc: DVDDisc) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "opticaldisc.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text(disc.volumeName)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            Text("DVD detected. Scan to find titles.")
                .font(.body)
                .foregroundStyle(.gray)

            Button {
                hasScanned = true
                Task {
                    await service.scanTitles(for: disc)
                    if let updated = service.detectedDiscs.first(where: { $0.id == disc.id }) {
                        for title in updated.titles {
                            titleNames[title.id] = title.name
                        }
                    }
                }
            } label: {
                Label("Scan Titles", systemImage: "magnifyingglass")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(spacing: 24) {
            ProgressView(value: service.scanProgress)
                .tint(.blue)

            Text(service.scanStatus)
                .font(.headline)
                .foregroundStyle(.white)

            Text("\(Int(service.scanProgress * 100))%")
                .font(.largeTitle.monospacedDigit())
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding()
    }

    // MARK: - No Titles

    private var noTitlesView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundStyle(.orange)
            Text("No Titles Found")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            Text("Could not find any video titles on this disc. Make sure ffprobe is installed.")
                .font(.body)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    // MARK: - Title List

    private func titleListView(_ disc: DVDDisc) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Disc header
                HStack {
                    Image(systemName: "opticaldisc.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(disc.volumeName)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("\(disc.titles.count) title\(disc.titles.count == 1 ? "" : "s") found")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }
                    Spacer()

                    Button {
                        if selectedTitleIDs.count == disc.titles.count {
                            selectedTitleIDs.removeAll()
                        } else {
                            selectedTitleIDs = Set(disc.titles.map(\.id))
                        }
                    } label: {
                        Text(selectedTitleIDs.count == disc.titles.count ? "Deselect All" : "Select All")
                            .font(.caption)
                    }
                    .buttonStyle(.glass)
                }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))

                // Title rows
                ForEach(disc.titles) { title in
                    titleRow(title)
                }

                // Import button
                if !selectedTitleIDs.isEmpty {
                    importButton(disc)
                }
            }
            .padding(24)
        }
    }

    private func titleRow(_ title: DVDTitle) -> some View {
        let isSelected = selectedTitleIDs.contains(title.id)

        return HStack(spacing: 16) {
            Button {
                if isSelected {
                    selectedTitleIDs.remove(title.id)
                } else {
                    selectedTitleIDs.insert(title.id)
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? .blue : .gray)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Title name", text: Binding(
                    get: { titleNames[title.id] ?? title.name },
                    set: { titleNames[title.id] = $0 }
                ))
                .font(.headline)
                .foregroundStyle(.white)
                .textFieldStyle(.plain)

                HStack(spacing: 8) {
                    Label(title.formattedDuration, systemImage: "clock")
                    Label(title.resolution, systemImage: "rectangle.on.rectangle")
                }
                .font(.caption)
                .foregroundStyle(.gray)

                if !title.audioTracks.isEmpty {
                    Text(title.audioTracks.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.gray.opacity(0.7))
                }
            }

            Spacer()

            if let progress = service.conversionProgress[title.id] {
                VStack(spacing: 4) {
                    ProgressView(value: progress)
                        .frame(width: 60)
                        .tint(.blue)
                    Text(service.conversionStatus[title.id] ?? "")
                        .font(.system(size: 9))
                        .foregroundStyle(.gray)
                    if let eta = service.estimatedTimeRemaining(for: title.id) {
                        Text(eta)
                            .font(.system(size: 9))
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
        .padding(16)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
    }

    private func importButton(_ disc: DVDDisc) -> some View {
        Button {
            let selectedTitles = disc.titles.filter { selectedTitleIDs.contains($0.id) }
            let outputDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("DVDImport-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            Task {
                await service.convertTitles(selectedTitles, names: titleNames, outputDirectory: outputDir, disc: disc)
                try? FileManager.default.removeItem(at: outputDir)
            }
        } label: {
            Label("Import \(selectedTitleIDs.count) Title\(selectedTitleIDs.count == 1 ? "" : "s")", systemImage: "square.and.arrow.down")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(service.isConverting)
    }

    // MARK: - Conversion Overlay

    private var conversionOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Converting…")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                ForEach(Array(service.conversionProgress.keys.sorted()), id: \.self) { titleId in
                    VStack(spacing: 4) {
                        HStack {
                            Text(titleNames[titleId] ?? "Title \(titleId)")
                                .font(.caption)
                                .foregroundStyle(.white)
                            Spacer()
                            ProgressView(value: service.conversionProgress[titleId] ?? 0)
                                .frame(width: 120)
                                .tint(.blue)
                            Text("\(Int((service.conversionProgress[titleId] ?? 0) * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.gray)
                                .frame(width: 40, alignment: .trailing)
                        }
                        if let eta = service.estimatedTimeRemaining(for: titleId) {
                            Text(eta)
                                .font(.caption2)
                                .foregroundStyle(.gray)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }

                if service.conversionProgress.values.allSatisfy({ $0 >= 1.0 }) {
                    Label("All titles imported!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                }
            }
            .padding(32)
            .frame(maxWidth: 400)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }
}

// MARK: - Error Alert

extension DVDImportView {
    @ViewBuilder
    private var errorAlert: some View {
        EmptyView()
            .alert("Error", isPresented: .init(
                get: { service.errorMessage != nil },
                set: { if !$0 { service.errorMessage = nil } }
            )) {
                Button("OK") { service.errorMessage = nil }
            } message: {
                Text(service.errorMessage ?? "")
            }
    }
}
#endif
