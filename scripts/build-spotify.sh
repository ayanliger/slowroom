#!/bin/zsh
set -eu

slowroom_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -x "$slowroom_root/build/cargo/bin/cargo" ]]; then
    export RUSTUP_HOME="$slowroom_root/build/rustup"
    export CARGO_HOME="$slowroom_root/build/cargo"
    slowroom_cargo="$CARGO_HOME/bin/cargo"
else
    slowroom_cargo="$(command -v cargo)"
fi
export CARGO_TARGET_DIR="$slowroom_root/build/native-spotify/cargo"
export IPHONEOS_DEPLOYMENT_TARGET=18.0

case "${PLATFORM_NAME:-iphoneos}" in
    iphoneos) slowroom_target=aarch64-apple-ios ;;
    iphonesimulator) slowroom_target=aarch64-apple-ios-sim ;;
    *) print -u2 'The Spotify bridge supports iPhone and Apple silicon simulators.'; exit 1 ;;
esac

"$slowroom_cargo" build --manifest-path "$slowroom_root/NativeSpotify/Cargo.toml" --target "$slowroom_target" --release --locked
slowroom_output="$slowroom_root/build/native-spotify/${PLATFORM_NAME:-iphoneos}"
mkdir -p "$slowroom_output"
cp "$CARGO_TARGET_DIR/$slowroom_target/release/libslowroom_spotify.a" "$slowroom_output/libslowroom_spotify.a"
