# Contributing to Imora

Contributions are welcome. This document covers everything needed to build the project and find your way around the code. By contributing you agree that your work is released under the project's [license](LICENSE.md).

Imora is a SwiftUI app built with Xcode. The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen), so the source of truth is `project.yml`, not the `.xcodeproj`.

## Prerequisites

- macOS with Xcode 27 (iOS 26 SDK) or newer.
- XcodeGen: `brew install xcodegen`.
- An Apple Developer account added to Xcode for device runs.
- An Immich server to test against, v3.x API.

## Generating the Xcode project

The `.xcodeproj` is generated and git-ignored. After cloning, and after any change to `project.yml`, run:

```sh
xcodegen generate
```

Do not edit `Imora.xcodeproj` by hand. Change `project.yml` and regenerate, so settings stay reproducible and diffs stay small.

Both targets are Xcode synchronized folders: the files on disk under `Imora/` and `ImoraShare/` are the target membership. Adding, moving or deleting a Swift file needs no regeneration. Regenerate when you change build settings, Info.plist keys, entitlements, packages or the scheme.

## Project layout

- `project.yml` declares both targets, their build settings, the Nuke package and the `Imora` scheme. Usage strings and the other generated Info.plist keys live there under the app target's settings.
- `Imora/` holds the app. `Imora/Info.plist` carries the keys that cannot be expressed as build settings, such as background modes and task identifiers, and `Imora/Imora.entitlements` declares the app group.
- `Imora/AppIcon.icon` is the Icon Composer app icon. `Imora/Assets.xcassets` holds the accent color, the brand tint and the login mark.
- `ImoraShare/` holds the share extension with its own `Info.plist` and entitlements.

The app group and the share task identifier are the `IMORA_APP_GROUP` and `IMORA_SHARE_TASK_ID` build settings in `project.yml`. Both plists and both entitlements files reference them as variables, so they are defined in one place.

## Dependencies

Declared in `project.yml` and resolved by Swift Package Manager on first build:

- [Nuke](https://github.com/kean/Nuke) 13, the image pipeline behind every thumbnail: memory and disk caching, request coalescing, prefetching, a rate limiter for fast scrolling and resumable downloads.

Everything else is system frameworks. Device thumbnails go through PhotoKit's own `PHCachingImageManager`, checksums through CryptoKit, and the REST layer is `URLSession` with `Codable`.

## Building and running

Open `Imora.xcodeproj`, pick a Simulator or a connected device, and run. Signing is automatic: Xcode registers the `com.vexcited.imora` App IDs and the `group.com.vexcited.imora` app group on the first device build. The project targets team `WLAPHT4WXV`; change `DEVELOPMENT_TEAM` in `project.yml` if you build on your own team, and keep that change out of your pull request.

Command-line build:

```sh
xcodebuild build -project Imora.xcodeproj -scheme Imora \
  -destination 'generic/platform=iOS Simulator'
```

Backups and share uploads run through `BGContinuedProcessingTask`, which the simulator rejects. Those paths fall back to an in-app run there, so use a physical device to see the Dynamic Island and Lock Screen progress.

## Architecture

```
Imora/
  App/            entry point, root tab shell
  Core/
    API/          ImmichClient (async REST), SessionStore
    Models/       codable dtos, columnar time-bucket decoding
    Images/       ImageLoader (Nuke pipeline), PhotoKit loader, prefetcher, thumbhash decoder
    Realtime/     socket.io channel, live grid updates
    Notifications/ server inbox, UserNotifications bridge, tap routing
    Storage/      keychain wrapper
  DesignSystem/   RemoteImage, asset tiles
  Features/       Auth, Timeline, Viewer, Albums, Search, Library, Map, Notifications, Settings
ImoraShare/       share extension: staging into the app group, background uploads
```

Immich has no push transport: notifications arrive on the same socket the timeline uses, so Imora raises them as local notifications while it runs and replays anything missed, capped at five, the next time the inbox is fetched.

Backup progress is fed to `BGContinuedProcessingTask`, which draws the system progress UI itself. The API is only for work the user explicitly asked for, so "Back Up Now" submits one and library-change reruns stay on the plain in-app path. The scheduler expires tasks that stop reporting, so byte progress from in-flight uploads is folded into the bar as well as completed-file counts. The same machinery drives the share upload, through a `ContinuedWorkload` both jobs conform to.

iOS forbids a share extension from opening its containing app, so `ImoraShare` copies what it is given into the app group, writes a `<uuid>.json` descriptor next to it, one file per drop so the two processes never write the same file and need no coordination, and posts a notification. Imora picks the inbox up every time it comes forward.

Uploads run on one background `URLSession`, so the transfer belongs to the system rather than the app process. The multipart body is written to Application Support, not tmp or caches, which the system may reclaim while the app is away. The ticket needed to finish the job, including the account it belongs to, rides along in the task description that the system persists. A completion with no caller waiting is applied straight to the backup index, so nothing is ever uploaded twice; one that is lost entirely is picked up by the next run's checksum pass instead. Exporting still needs the app awake, so the handoff is bounded by how many files are staged when it is suspended.

The timeline mirrors the server's bucket API: `GET /timeline/buckets` returns month buckets, each grid section fetches `GET /timeline/bucket` on demand and decodes the columnar (struct-of-arrays) payload into assets.

## Style

- Swift 5 language mode with approachable concurrency and `MainActor` default isolation. Keep new code data-race safe rather than silencing warnings.
- SwiftUI first. Keep views small and hold state in observable stores under `Core`.
- Match the existing file and type layout.
- There is no test target and pull requests should not add one.

## Pull requests

- Keep each pull request focused on one change.
- Use conventional commit messages: `type: short description`.
- Make sure `xcodegen generate` and a build pass before you request review.
