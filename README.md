# Imora

A native SwiftUI client for [Immich](https://immich.app), built for iOS 26 with Liquid Glass. No cross-platform layer: SwiftUI, the iOS 26 design language and the Immich REST API.

## Features

- Photo timeline with month sections, memories, a drag scrubber and live updates from the server.
- Full-screen viewer with zoom, video playback, EXIF and map, favorite, archive, trash and share.
- Albums with sharing, public links, activity and covers, plus multi-select actions everywhere.
- Smart search, people, places, favorites, archive, trash and a locked folder behind Face ID.
- Photo map with clustering and filters.
- Backups that keep running after you leave the app, with progress in the Dynamic Island and on the Lock Screen.
- Share extension that uploads photos and videos from any app.
- Notifications inbox for album invites, activity and server alerts, mirrored as iOS banners.
- Admin panel for users and job queues.

## Requirements

- iOS 26 or newer.
- An Immich server, v3.x API.

## Build

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) and is not committed:

```sh
brew install xcodegen
xcodegen generate
open Imora.xcodeproj
```

Pick a Simulator or your iPhone and run. Signing, the command-line build and an architecture tour are in [CONTRIBUTING.md](CONTRIBUTING.md).
