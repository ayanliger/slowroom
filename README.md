# Slowroom

[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](Packages/SlowroomCore/Package.swift) [![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-147EFB?logo=swift&logoColor=white)](https://developer.apple.com/xcode/swiftui/) [![iOS 18+](https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white)](Slowroom.xcodeproj/project.pbxproj) [![Xcode 27.1](https://img.shields.io/badge/Xcode-27.1-147EFB?logo=xcode&logoColor=white)](https://developer.apple.com/xcode/) [![Rust 2024](https://img.shields.io/badge/Rust-2024-CE422B?logo=rust&logoColor=white)](NativeSpotify/Cargo.toml) [![Personal prototype](https://img.shields.io/badge/State-personal_prototype-9A6700?logo=apple&logoColor=white&labelColor=555555)](#status)

A personal iPhone audio deck with live speed, pitch and reverb controls for YouTube audio and local files. A local library stores sources and finished mixes, with search, queued playback, renaming and Files import. Spotify sign-in works, but full Spotify playback is currently blocked by audio-key refusals for the tested Premium account; see [Status](#status). The charcoal and rose-pink interface takes its spacing and numeric readouts from studio rack effects.

## Sources

| Input | Audio source | Requirement |
| --- | --- | --- |
| Experimental Spotify track link | Spotify, through the on-device librespot client | Premium sign-in; full playback currently blocked in testing |
| YouTube video or Music link | The linked YouTube upload | Internet access; accessible stereo AAC stream |
| Audio or video file | The selected local file | Audio that AVFoundation can decode |

The Spotify integration requests the linked Spotify recording. YouTube extraction runs on the iPhone through YouTubeKit. The audio loads into a local file before the live effect controls become available. Both service integrations are unofficial and can stop working when their services change; the official playback SDKs do not expose the decoded audio this app needs.

## Local library

Open Library > Import to select audio files or a folder from Files. Subfolders are scanned for audio and video. Existing mixes belong in Slowed + Reverb; recordings for later editing belong in Sources. Every library track plays at its saved speed without added pitch or reverb. Open in deck applies the deck settings for further editing, and Save mix to library renders a separate M4A copy; WAV export remains available in the deck menu.

Library copies are stored in Files > On My iPhone > Slowroom > Slowroom Library, with separate Slowed + Reverb and Sources folders. Titles and artists come from embedded tags when available, otherwise filenames; recognized downloader prefixes, video labels and export-tool suffixes are removed while remaster and version labels are retained. Existing entries with those export artifacts are cleaned on launch, and Rename updates the catalog and filename together. Imports preserve the selected originals, skip byte-identical duplicates and report failures per file. The catalog uses relative paths in Application Support so app-container changes do not invalidate its entries. Moving or renaming library files outside the app requires importing them again.

With Reduce lossless file sizes enabled, WAV, AIFF, FLAC and ALAC are encoded as AAC in M4A at 256 kb/s for stereo or 128 kb/s for mono. Sample rates above 48 kHz are converted to 48 kHz. Existing MP3 and AAC files are copied without re-encoding. Converted files are decoded and checked for matching duration before insertion, and the smaller copy is retained. The import report shows measured original and stored sizes; originals are never deleted by the importer.

To remove originals after import, open Library options > Delete imported originals and select their folder or files again. Slowroom matches each original by filename, size and SHA-256, then verifies the current library copy against its stored checksum. The preview lists eligible files before deletion; both files are checked again under file coordination when deleting. Changed originals, missing or damaged copies, symbolic links and files inside the library are kept. A cleanup receipt is saved in Application Support, and the screen reports partial failures or cancellation.

## Spotify alternatives investigated

The [official iOS SDK](https://developer.spotify.com/documentation/ios) controls the Spotify app rather than exposing audio samples. The embedded Media Delivery API separates fetching from decoding, but [access requires a hardware company application and approval](https://developer.spotify.com/documentation/commercial-hardware/onboarding). Dotify's [Web AAC fallback](https://github.com/AsHfIEXE/Dotify/blob/main/dotify/interface/audio.py) requires a supplied Widevine device file; its code does not provide a ready iPhone alternative to the current login.

[Spotdown](https://spotdown.org/en2) resolves a Spotify link without asking the user to sign in. Its public client sends the link to its own download endpoint, and its footer states that it uses third-party services. The upstream recording source has not been verified. A server-backed downloader can be used from an iPhone without a Mac helper, but it is different from extracting Spotify audio on the phone. Files downloaded in Safari can be imported into the local library.

## Build and run

Use Xcode 27.1 and Rust with edition 2024 support on an Apple silicon Mac. Install the Rust targets `aarch64-apple-ios` and `aarch64-apple-ios-sim` with `rustup target add`. Open `Slowroom.xcodeproj`, select your development team under Signing & Capabilities and run the Slowroom scheme on your iPhone. Xcode builds the Rust library through `scripts/build-spotify.sh`, which uses the project-local toolchain under `build/` when present, otherwise the `cargo` on your PATH. The app requires iOS 18 or later; a Mac is only needed to build and install it.

For local signing settings without changing the shared project, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and replace `YOUR_TEAM_ID` with your Apple development team ID. The local file is excluded from Git, along with credentials, downloaded audio and build output.

In the app, open Load a link > Spotify account > Sign in to Spotify. Sign-in uses the iPhone's system authentication browser and Spotify's device-authorization flow, without a callback server. Spotify may label this connection "Spotify for Desktop" because librespot uses that client identity for device authorization. The app checks whether Spotify accepts an audio session after authorization; a successful web sign-in alone does not verify playback. The built-in synth demo and YouTube importer work without a Spotify account.

## Development checks

```sh
swift test --package-path Packages/SlowroomCore --scratch-path build/core
cargo test --manifest-path NativeSpotify/Cargo.toml --locked
cargo test --manifest-path NativeSpotify/Cargo.toml --locked -p librespot-core --no-default-features --features rustls-tls-webpki-roots audio_key::tests
swift run --package-path Packages/SlowroomCore --scratch-path build/core SourceProbe 'YOUTUBE_URL'
```

The Swift tests measure rendered duration, frequency and reverb tails using generated signals. Library checks cover AAC size and duration, resampling, duplicate detection, filename collisions, persistence and failed catalog writes. The Xcode scheme includes UI checks for library playback and renaming, folder selection, live controls, input errors, WAV export and a public YouTube sample. Rust tests cover native job ownership, cancellation, track IDs and error redaction. `SourceProbe` checks Spotify metadata or downloads a YouTube sample; Spotify authentication and audio require the iPhone app. The vendored sysinfo and librespot-core compatibility changes are documented in [NativeSpotify/vendor/README.md](NativeSpotify/vendor/README.md).

## Status

Personal prototype, version 0.1.0, with no tagged release or selected license for the original source. The phone-only build is signed and installed on a physical iPhone. Spotify browser sign-in and the native audio-session connection are verified on that device. Full Spotify playback failed on two tracks for the tested Premium account; the second test still received audio-key refusal code 1 after the bounded retry sequence, matching the unresolved [librespot issue 1649](https://github.com/librespot-org/librespot/issues/1649).

Live controls and YouTube import/playback passed on the physical iPhone. Library playback, automatic queue advancement, renaming, persistence, saving a compressed mix, original cleanup and opening the folder picker also passed device checks using generated audio. Twenty-four core tests cover source handling, rendered audio and library operations, including memory use during large-file checks; WAV export was checked in the simulator. Dependency versions are pinned in the Swift package and Cargo lockfile; license notices are in [ThirdPartyNotices.txt](Slowroom/ThirdPartyNotices.txt).

The deck retains the current source in its cache and replaces older cached sources when another track loads. Keep source in library preserves a separate copy. Library files persist until removed through Files or the app is deleted; clearing the deck does not remove them. Exported WAV files go to the location selected in Files. Spotify tokens stay in the iPhone Keychain and are removed when signing out; reusable playback credentials are held in memory. No audio upload or publishing feature is included.
