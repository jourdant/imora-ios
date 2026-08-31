# Contributing to Imora

Contributions are welcome. This document covers everything needed to build the project and find your way around the code. By contributing you agree that your work is released under the project's [license](LICENSE) - AGPLv3 with the Commons Clause.

## Requirements

- Xcode 27 (iOS 26 SDK) or newer
- An Immich server to test against, v3.x API

## Dependencies

Resolved by Swift Package Manager on first build:

- [Nuke](https://github.com/kean/Nuke) 13 - the image pipeline behind every thumbnail: memory and disk caching, request coalescing, prefetching, a rate limiter for fast scrolling and resumable downloads.

Everything else is system frameworks. Device thumbnails go through PhotoKit's own `PHCachingImageManager`, checksums through CryptoKit, and the REST layer is `URLSession` with `Codable`.

## Development

Open `Imora.xcodeproj` and run:

```sh
xcodebuild build -project Imora.xcodeproj -scheme Imora \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
```

In debug builds the login screen honors `IMORA_SERVER`, `IMORA_EMAIL` and `IMORA_PASSWORD` environment variables for automatic sign-in (`SIMCTL_CHILD_`-prefixed when launching via `simctl`).

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

Immich has no push transport: notifications arrive on the same socket the timeline
uses, so Imora raises them as local notifications while it runs and replays
anything missed - capped at five - the next time the inbox is fetched.

Backup progress is fed to `BGContinuedProcessingTask`, which draws the system
progress UI itself. The API is only for work the user explicitly asked for, so
"Back Up Now" submits one and library-change reruns stay on the plain in-app
path. The scheduler expires tasks that stop reporting, so byte progress from
in-flight uploads is folded into the bar as well as completed-file counts. The
simulator rejects submission with `.unavailable`; the caller falls back to an
in-app run, so this needs a device to see. The same machinery drives the share
upload, through a `ContinuedWorkload` both jobs conform to.

iOS forbids a share extension from opening its containing app, so `ImoraShare`
copies what it is given into the app group, writes a `<uuid>.json` descriptor
next to it - one file per drop, so the two processes never write the same file
and need no coordination - and posts a notification. Imora picks the inbox up
every time it comes forward.

Uploads run on one background `URLSession`, so the transfer belongs to the
system rather than the app process. The multipart body is written to
Application Support - not tmp or caches, which the system may reclaim while the
app is away - and the ticket needed to finish the job, including the account it
belongs to, rides along in the task description that the system persists. A
completion with no caller waiting is applied straight to the backup index, so
nothing is ever uploaded twice; one that is lost entirely is picked up by the
next run's checksum pass instead. Exporting still needs the app awake, so the
handoff is bounded by how many files are staged when it is suspended.

The timeline mirrors the server's bucket API: `GET /timeline/buckets` returns month buckets, each grid section fetches `GET /timeline/bucket` on demand and decodes the columnar (struct-of-arrays) payload into assets.
