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

- An Immich server, v3.x API

## Contributing

Build requirements, instructions and an architecture tour live in [CONTRIBUTING.md](CONTRIBUTING.md).
