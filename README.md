# Photo Box

A SwiftUI video library manager for iOS and iPad, with Mac support via Designed for iPad.

## Features

- **Video Library Browser** — Grid view of all videos from your photo library with poster-style cards, duration badges, and Liquid Glass effects
- **Search** — Filter videos by date, year, duration, resolution (4K, 1080p, 720p), or favorites
- **Year Grouping** — Organize videos by year with automatic year estimation from resolution heuristics
- **Duplicate Detection** — Three-tier scanning to find duplicate and similar videos:
  - Exact duplicates (matching resolution, duration, and file size)
  - Near duplicates (same resolution, duration within 3 seconds)
  - Visually similar (Vision framework feature print comparison)
- **Year Mismatch Detection** — Flags videos whose metadata date doesn't match the expected era based on resolution/aspect ratio heuristics
- **Video Editor** — Trim and split videos with a filmstrip timeline, export to photo library
- **Multi-Window** — Videos open in a separate window on iPad and Mac; zoom transition on iPhone
- **Favorites & Date Editing** — Favorite videos and change creation dates with suggested year corrections
- **Context Menus** — Right-click actions throughout the app

## Requirements

- iOS 26.2+
- Xcode 16+

## Architecture

- SwiftUI + SwiftData
- PhotoKit for library access
- AVKit / AVFoundation for playback and export
- Vision framework for visual similarity analysis
- Modern Swift concurrency (async/await)

## Privacy

Photo Box requires photo library access to display and manage your videos. All analysis is performed on-device.
