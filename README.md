# imora

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
- Places: an Apple Maps photo map with client-side clustering, marker thumbnails, filters (favorites, archive, partners, shared albums, date range) and a grid of everything inside the visible area
- Multi-select everywhere with a Liquid Glass action bar: favorite, archive, add to album, trash, restore
- Thumbhash placeholders, downsampled decoding and a 1 GiB disk cache for fast scrolling

## Requirements

- Xcode 27 (iOS 26 SDK) or newer
- An Immich server, v2.x/3.x API

## Development

Open `imora.xcodeproj` and run. The UI test suite (`imoraUITests`) drives a full walkthrough against the public Immich demo server and captures screenshots as attachments:

```sh
xcodebuild test -project imora.xcodeproj -scheme imora \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
```

In debug builds the login screen honors `IMORA_SERVER`, `IMORA_EMAIL` and `IMORA_PASSWORD` environment variables for automatic sign-in (`SIMCTL_CHILD_`-prefixed when launching via `simctl`).

## Architecture

```
imora/
  App/            entry point, root tab shell
  Core/
    API/          ImmichClient (async REST), SessionStore
    Models/       codable dtos, columnar time-bucket decoding
    Images/       ImageLoader (memory + disk cache), thumbhash decoder
    Storage/      keychain wrapper
  DesignSystem/   RemoteImage, asset tiles
  Features/       Auth, Timeline, Viewer, Albums, Search, Library, Map, Settings
```

The timeline mirrors the server's bucket API: `GET /timeline/buckets` returns month buckets, each grid section fetches `GET /timeline/bucket` on demand and decodes the columnar (struct-of-arrays) payload into assets.
