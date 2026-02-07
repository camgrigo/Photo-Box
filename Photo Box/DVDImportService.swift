//
//  DVDImportService.swift
//  Photo Box
//
//  Created by Cameron Grigoriadis on 2/6/26.
//

#if os(macOS)
import Foundation
import AppKit
import Observation
import Photos

struct DVDTitle: Identifiable {
    let id: Int
    let vobFiles: [URL]
    let duration: TimeInterval
    let resolution: String
    let audioTracks: [String]
    var name: String

    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct DVDDisc: Identifiable {
    let id = UUID()
    let volumeName: String
    let mountPoint: URL
    let videoTSPath: URL
    var titles: [DVDTitle] = []
}

@Observable
@MainActor
final class DVDImportService {
    var detectedDiscs: [DVDDisc] = []
    var isScanning = false
    var isDetecting = false
    var scanProgress: Double = 0
    var scanStatus = ""
    var conversionProgress: [Int: Double] = [:]
    var conversionStatus: [Int: String] = [:]
    var conversionStartTime: [Int: Date] = [:]
    var isConverting = false
    var errorMessage: String?

    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?
    private var detectionTask: Task<Void, Never>?

    func estimatedTimeRemaining(for titleId: Int) -> String? {
        guard let start = conversionStartTime[titleId],
              let progress = conversionProgress[titleId],
              progress > 0.01, progress < 1.0 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = elapsed / progress * (1 - progress)
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s remaining"
        }
        return "\(seconds)s remaining"
    }

    // MARK: - DVD Detection

    func startObservingDiscs() {
        detectDVDs()

        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.detectDVDs()
            }
        }

        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                if let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    self?.detectedDiscs.removeAll { $0.mountPoint == volumeURL }
                }
            }
        }
    }

    func stopObservingDiscs() {
        if let observer = mountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = unmountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func detectDVDs() {
        detectionTask?.cancel()
        detectionTask = Task {
            isDetecting = true
            defer { isDetecting = false }

            // Retry a few times to allow disc spin-up / mount
            for attempt in 0..<6 {
                if Task.isCancelled { return }
                let discs = scanForDiscs()
                if !discs.isEmpty {
                    detectedDiscs = discs
                    return
                }
                if attempt < 5 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            detectedDiscs = []
        }
    }

    private func scanForDiscs() -> [DVDDisc] {
        let fileManager = FileManager.default
        guard let volumes = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil
        ) else { return [] }

        var discs: [DVDDisc] = []
        for volume in volumes {
            let videoTS = volume.appendingPathComponent("VIDEO_TS")
            if fileManager.fileExists(atPath: videoTS.path) {
                discs.append(DVDDisc(
                    volumeName: volume.lastPathComponent,
                    mountPoint: volume,
                    videoTSPath: videoTS
                ))
            }
        }
        return discs
    }

    // MARK: - Title Scanning

    func scanTitles(for disc: DVDDisc) async {
        isScanning = true
        scanProgress = 0
        scanStatus = "Scanning VIDEO_TS…"
        defer { isScanning = false }

        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: disc.videoTSPath,
            includingPropertiesForKeys: nil
        ) else {
            errorMessage = "Could not read VIDEO_TS directory"
            return
        }

        // Find IFO files (VTS_XX_0.IFO) to identify title sets
        let ifoFiles = files.filter { $0.pathExtension.uppercased() == "IFO" && $0.lastPathComponent.uppercased().hasPrefix("VTS_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var titles: [DVDTitle] = []
        let total = Double(ifoFiles.count)

        for (index, ifo) in ifoFiles.enumerated() {
            let filename = ifo.deletingPathExtension().lastPathComponent.uppercased()
            // Extract title number from VTS_XX_0
            guard let titleNumStr = filename.split(separator: "_").dropFirst().first,
                  let titleNum = Int(titleNumStr) else { continue }

            scanStatus = "Probing title \(titleNum)…"
            scanProgress = Double(index) / total

            // Find VOB files for this title set (VTS_XX_1.VOB, VTS_XX_2.VOB, ...)
            let vobPrefix = String(format: "VTS_%02d_", titleNum)
            let vobFiles = files.filter { file in
                let name = file.lastPathComponent.uppercased()
                return name.hasPrefix(vobPrefix) && name.hasSuffix(".VOB") && !name.hasSuffix("_0.VOB")
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }

            guard !vobFiles.isEmpty else { continue }

            // Probe the first VOB to get stream info
            if let titleInfo = await probeVOBs(vobFiles, titleNumber: titleNum) {
                titles.append(titleInfo)
            }
        }

        // Update the disc with scanned titles
        if let discIndex = detectedDiscs.firstIndex(where: { $0.id == disc.id }) {
            detectedDiscs[discIndex].titles = titles
        }

        scanProgress = 1.0
        scanStatus = "Done — \(titles.count) title\(titles.count == 1 ? "" : "s") found"
    }

    private func probeVOBs(_ vobFiles: [URL], titleNumber: Int) async -> DVDTitle? {
        let concatPath = vobFiles.map(\.path).joined(separator: "|")

        guard let (output, _) = try? await runProcess(
            executablePath: Self.ffprobePath,
            arguments: [
                "-v", "quiet",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                "concat:\(concatPath)"
            ]
        ) else { return nil }

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Parse duration
        var duration: TimeInterval = 0
        if let format = json["format"] as? [String: Any],
           let durationStr = format["duration"] as? String,
           let dur = Double(durationStr) {
            duration = dur
        }

        // Skip very short titles (menu screens, etc.)
        guard duration > 30 else { return nil }

        // Parse streams
        var resolution = "Unknown"
        var audioTracks: [String] = []

        if let streams = json["streams"] as? [[String: Any]] {
            for stream in streams {
                let codecType = stream["codec_type"] as? String ?? ""
                if codecType == "video" {
                    let width = stream["width"] as? Int ?? 0
                    let height = stream["height"] as? Int ?? 0
                    if width > 0 && height > 0 {
                        resolution = "\(width)×\(height)"
                    }
                } else if codecType == "audio" {
                    let codecName = stream["codec_name"] as? String ?? "unknown"
                    let channels = stream["channels"] as? Int ?? 0
                    let channelDesc = channels == 6 ? "5.1" : channels == 2 ? "stereo" : "\(channels)ch"
                    let lang = (stream["tags"] as? [String: Any])?["language"] as? String
                    var desc = "\(codecName) \(channelDesc)"
                    if let lang { desc += " (\(lang))" }
                    audioTracks.append(desc)
                }
            }
        }

        return DVDTitle(
            id: titleNumber,
            vobFiles: vobFiles,
            duration: duration,
            resolution: resolution,
            audioTracks: audioTracks,
            name: "Title \(titleNumber)"
        )
    }

    // MARK: - Conversion

    func convertTitles(_ titles: [DVDTitle], names: [Int: String], outputDirectory: URL, disc: DVDDisc) async {
        isConverting = true
        defer { isConverting = false }

        for title in titles {
            conversionProgress[title.id] = 0
            conversionStatus[title.id] = "Starting…"
        }

        for title in titles {
            let name = names[title.id] ?? title.name
            await convertTitle(title, name: name, outputDirectory: outputDirectory)
        }

        // Eject disc
        _ = try? await runProcess(
            executablePath: "/usr/bin/diskutil",
            arguments: ["eject", disc.mountPoint.path]
        )
    }

    private func convertTitle(_ title: DVDTitle, name: String, outputDirectory: URL) async {
        let concatPath = title.vobFiles.map(\.path).joined(separator: "|")
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let outputFile = outputDirectory
            .appendingPathComponent(safeName)
            .appendingPathExtension("mp4")

        conversionStartTime[title.id] = Date()
        conversionStatus[title.id] = "Converting with VideoToolbox…"

        // Try VideoToolbox first, fallback to libx264
        let videoToolboxArgs = [
            "-y",
            "-i", "concat:\(concatPath)",
            "-c:v", "h264_videotoolbox",
            "-b:v", "5M",
            "-c:a", "aac",
            "-b:a", "192k",
            "-progress", "pipe:1",
            outputFile.path
        ]

        let libx264Args = [
            "-y",
            "-i", "concat:\(concatPath)",
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", "22",
            "-c:a", "aac",
            "-b:a", "192k",
            "-progress", "pipe:1",
            outputFile.path
        ]

        let success = await runFFmpegConversion(
            arguments: videoToolboxArgs,
            titleId: title.id,
            totalDuration: title.duration
        )

        if !success {
            conversionStatus[title.id] = "Falling back to software encoding…"
            conversionProgress[title.id] = 0
            conversionStartTime[title.id] = Date()
            _ = await runFFmpegConversion(
                arguments: libx264Args,
                titleId: title.id,
                totalDuration: title.duration
            )
        }

        // Import to Photos
        if FileManager.default.fileExists(atPath: outputFile.path) {
            conversionStatus[title.id] = "Importing to Photos…"
            do {
                try await importToPhotos(fileURL: outputFile)
                conversionStatus[title.id] = "Done"
                conversionProgress[title.id] = 1.0
            } catch {
                conversionStatus[title.id] = "Import failed: \(error.localizedDescription)"
            }

            try? FileManager.default.removeItem(at: outputFile)
        } else {
            conversionStatus[title.id] = "Conversion failed"
        }
    }

    private func runFFmpegConversion(arguments: [String], titleId: Int, totalDuration: TimeInterval) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.ffmpegPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }

        // Parse progress from stdout
        let fileHandle = pipe.fileHandleForReading
        let stream = fileHandle.bytes

        var currentTime: TimeInterval = 0

        // Read line by line from the progress pipe
        var lineBuffer = Data()
        do {
            for try await byte in stream {
                if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                    if let line = String(data: lineBuffer, encoding: .utf8) {
                        if line.hasPrefix("out_time_us="), let microseconds = Double(line.replacingOccurrences(of: "out_time_us=", with: "")) {
                            currentTime = microseconds / 1_000_000
                            let progress = min(currentTime / totalDuration, 0.99)
                            await MainActor.run {
                                self.conversionProgress[titleId] = progress
                            }
                        }
                    }
                    lineBuffer = Data()
                } else {
                    lineBuffer.append(byte)
                }
            }
        } catch {
            // Stream ended or read error — continue to check exit status
        }

        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Photos Import

    private func importToPhotos(fileURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: fileURL, options: nil)
        }
    }

    // MARK: - Tool Paths

    private static let ffprobePath: String = {
        for path in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "ffprobe"
    }()

    private static let ffmpegPath: String = {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "ffmpeg"
    }()

    // MARK: - Process Helper

    private func runProcess(executablePath: String, arguments: [String]) async throws -> (String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}
#endif
