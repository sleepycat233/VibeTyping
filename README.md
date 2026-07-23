# VibeTyping

VibeTyping is a native macOS 15 menu-bar dictation app with a small always-on-top
desktop companion. Hold `Control+Option+Space`, speak, and release to paste the
final transcript into the focused application.

All speech processing runs locally. The app manages a bundled Qwen3-ASR helper
on `127.0.0.1`, records 24 kHz mono audio, streams it over a local WebSocket, and
uses Accessibility only for the final paste operation.

## Features

- Push-to-talk dictation with short-press cancellation and a 30-second limit
- Local Qwen3-ASR transcription with no hosted API dependency
- Clipboard paste with CJK input-source protection
- Menu-bar controls and microphone selection
- Codex-compatible animated desktop companion
- Managed local helper process with health and token-conflict checks

## Requirements

- Apple Silicon Mac
- macOS 15 or newer
- Xcode with the macOS 15 SDK
- Microphone permission
- Accessibility permission for automatic paste

## Clone

The speech runtime is pinned as a submodule. Clone recursively:

```bash
git clone --recurse-submodules https://github.com/sleepycat233/VibeTyping.git
cd VibeTyping
```

For an existing checkout:

```bash
git submodule update --init --recursive
```

## Build The App

```bash
make app
open App/VibeTyping.app
```

The development build is ad-hoc signed. The first launch downloads and loads the
local speech models, so initial readiness can take substantially longer than
later launches. Restart VibeTyping after granting Accessibility permission.

## Development

Run all unit tests:

```bash
make test
```

Run the client directly during development:

```bash
make -C Server debug
cd App
swift run --disable-sandbox VibeTyping
```

The app and server remain separate processes. The packaged app embeds the server
executable, its SwiftPM resource bundles, `mlx.metallib`, and the default v2 pet.

See [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md) for protocol, state-machine,
audio, paste, helper ownership, pet runtime, and packaging details.

## Repository Layout

```text
App/                  macOS menu-bar application and app-bundle script
Server/               local realtime ASR helper and benchmarks
Vendor/speech-swift/  pinned speech runtime submodule
Docs/                 architecture documentation
```

## License

VibeTyping is licensed under the MIT License. See [LICENSE](LICENSE).

Third-party dependencies and bundled model resources retain their own licenses;
see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
