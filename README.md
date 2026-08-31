# Imora

A native SwiftUI client for [Immich](https://immich.app), rebuilt from the ground up for iOS 26 with Liquid Glass.

This is a rewrite of the official Flutter mobile app as a fully native iOS experience: no cross-platform layers, just SwiftUI, the iOS 26 design language and the Immich REST API.

## Features

- Two-step login flow with `/.well-known/immich` server resolution and Bearer session auth stored in the Keychain
- Bucketed photo timeline with month sections, day groups, lazy loading, pull-to-refresh and a drag scrubber
- Memories carousel ("x years ago") above the timeline
- Full-screen asset viewer: pinch zoom, paging, video playback, favorite / archive / trash, share of originals, EXIF info sheet with map
- Albums: list with filter chips, album detail grids with description header and shared avatars, create / edit / delete, add and remove photos, invite people, options with activity toggle and people management, leave shared albums, public shared links (create / edit / delete with password, custom URL and expiry)
- Search: CLIP smart search with paging, people and places discovery
- Library: favorites, archive and trash management, people browsing
- Notifications: a server inbox for album invites, album activity and server alerts with an unread badge on the timeline bell, swipe to mark read or delete, tap to jump to the album, plus iOS banners raised live from the realtime socket and caught up on launch - with per-type device switches, backup reports and the server's email notification settings
- Backups you start yourself run as a `BGContinuedProcessingTask`, so they keep going after you leave the app and report progress in the Dynamic Island and on the Lock Screen with the system's own cancel button
- Every upload goes through a background `URLSession`, so a transfer already handed to the system finishes even if the app is suspended or killed; completions that arrive with no run left to receive them are replayed into the backup index on the next launch
- A share extension takes photos and videos from any app: they are staged in a shared app group, and Imora uploads them from a screen showing a percentage per file, an overall bar and a View Photos button when it is done - leaving the app does not stop it
- Places: an Apple Maps photo map with client-side clustering, marker thumbnails, filters (favorites, archive, partners, shared albums, date range) and a grid of everything inside the visible area
- Multi-select everywhere with a Liquid Glass action bar: favorite, archive, add to album, trash, restore
- Thumbhash placeholders, thumbnail-sized decoding and a 1 GiB disk cache for fast scrolling, with grids prefetching a rolling window of tiles ahead of the fold

## Requirements

- Xcode 27 (iOS 26 SDK) or newer
- An Immich server, v3.x API

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
