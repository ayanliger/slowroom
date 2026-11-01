# iOS compatibility patches

`sysinfo/` contains the source of sysinfo 0.36.1 from crates.io. Its Apple implementation references macOS process-file APIs that libc does not expose on iOS. The patch makes `ProcessInner::open_files` return `None` on iOS, where that information is unavailable, and leaves the macOS implementation unchanged. Spotify uses this dependency for platform information; Slowroom does not enumerate other processes.

The upstream license is retained in `sysinfo/LICENSE`. Remove this local override when the pinned Spotify dependency accepts a sysinfo release with the iOS correction.

`librespot-core/` comes from librespot commit `99b6088bf3ea028f90192676ac1a337fa4b2ed12`. The `ios-desktop-client` feature selects the macOS protocol profile when compiled for iOS, matching the desktop OAuth client used for device authorization. The unmodified iOS profile rejected that token on a physical iPhone with `LoginFailed(TryAnotherAP)`; upstream tracks related mobile authentication issues in [issue 1477](https://github.com/librespot-org/librespot/issues/1477). The client continues to identify itself as librespot and uses the account's authorization for playback. This is a protocol compatibility setting; all decoding runs on the iPhone.

The core manifest resolves its workspace fields and sibling dependencies against that pinned revision. Build metadata uses the upstream revision and commit date instead of this project's Git history. The upstream license is retained in `librespot-core/LICENSE`.

Audio-key requests use the pacing and bounded backoff from [upstream pull request 1844](https://github.com/librespot-org/librespot/pull/1844), with its simulated-time tests. The returned error retains Spotify's numeric refusal code. No key is fabricated or substituted when Spotify refuses a request.
