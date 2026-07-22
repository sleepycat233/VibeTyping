# VibeTyping Architecture

> Status: phase 1 implementation baseline
> Date: 2026-07-21
> Scope: macOS 15+, Apple Silicon, local manual push-to-talk dictation

## Product Boundary

VibeTyping is one accessory GUI application plus one managed helper
process:

```text
VibeTyping.app
  GUI process: menu bar, hotkey, microphone, WebSocket, paste, pet
  child helper: remote-asr-server bound to 127.0.0.1:8080
```

The GUI remains a single process. The ASR service stays out of process so it can
retain its existing command-line server, model loading, telemetry, and Android
LAN-server use cases. The bundled helper is local-only; manually launched server
instances may continue to bind to the LAN for Android.

Phase 1 provides reliable original-text dictation only. LLM cleanup, semantic
editing, ambiguity bubbles, automatic endpointing, tunnels, mobile overlay work,
and cross-platform pet extraction remain backlog items.

## Runtime Layers

1. `AppModel` is the application coordinator and the only owner of the active
   dictation session.
2. `SessionStateMachine` defines valid state transitions independently of UI.
3. `ServerProcessManager` owns the local bearer token and only terminates a
   helper process it launched.
4. `RealtimeClient` owns a generation-scoped WebSocket connection and only
   accepts the final transcription event as dictation output.
5. `MicrophoneRecorder` converts the selected system input to 24 kHz mono
   Float32. `AudioPipeline` batches 100 ms and sends PCM16 little-endian data.
6. `PasteController` writes the clipboard and, when permitted, temporarily
   switches a CJK input method to an ASCII layout before synthesizing Cmd+V.
7. `PetPanelController` renders a Codex-compatible v1 or v2 atlas in a
   non-activating panel and maps session state to standard animation rows.

## Session Lifecycle

```text
startingServer -> idle -> listening -> transcribing -> applying -> ready -> idle
                                  \-> error ---------------------------> idle
```

- Pressing Control+Option+Space in `idle` clears the remote input buffer and
  starts capture.
- Releasing before 0.5 seconds stops capture and clears without committing.
- A normal release flushes the bounded local send queue before commit.
- The client counts audio samples and commits at 30 seconds even if wall-clock
  scheduling is delayed.
- Empty final text is not pasted.
- Any connection or send failure discards the active recording. Partial audio is
  never committed automatically after transport failure.

## Local Server Ownership

The app stores a random 32-byte token as a generic Keychain password. Startup
probes `GET /health`, then authenticates `GET /metrics`:

- compatible health plus authenticated metrics: reuse the existing service;
- compatible health plus rejected token: report a port/token conflict;
- incompatible HTTP response on port 8080: report a port conflict;
- connection refused: launch the bundled helper.

`/health` only becomes reachable after Qwen, Silero, and Smart Turn finish
loading, so it is the readiness signal. Helper stdout/stderr is diagnostic only.

## Realtime Contract

The client connects to `ws://127.0.0.1:8080/v1/realtime` with a bearer token.
After `session.created`, it sends one `session.update` requesting:

```json
{
  "model": "qwen3-asr",
  "input_audio_format": "pcm16",
  "input_audio_transcription": { "model": "qwen3-asr" },
  "turn_detection": null
}
```

The only final text source is
`conversation.item.input_audio_transcription.completed.transcript`. Response
events are tolerated and ignored. `realtime.keepalive` does not affect state.

## Audio Backpressure

Audio is grouped into 2,400-sample chunks: 100 ms at 24 kHz. The outbound queue
holds at most 48,000 PCM bytes, equal to one second of audio. Queue overflow is a
session error; chunks are never silently dropped. Commit waits on a queue flush
barrier.

## Paste And Privacy

Accessibility permission is optional for transcription. Without it, results are
copied but not pasted. Secure-field detection is best effort because third-party
applications do not expose uniform Accessibility metadata. The app never reads
the value of a secure field.

The phase 1 clipboard policy intentionally leaves the latest transcript on the
clipboard. Previous clipboard contents are not restored.

## Pet Compatibility

The loader accepts:

- v1: no `spriteVersionNumber`, 1536x1872, 8x9;
- v2: `spriteVersionNumber: 2`, 1536x2288, 8x11.

Both use 192x208 cells and eight columns. Sprite paths must be relative and stay
inside the pet directory. Phase 1 implements the standard rows only:

| Session state | Pet row |
| --- | --- |
| idle | idle (0) |
| listening | waiting (6) |
| startingServer, transcribing, applying | running (7) |
| ready | review (8) |
| error | failed (5) |

The in-process SwiftUI runtime is a deliberate macOS MVP decision. Loader,
animation, and state-mapping boundaries remain independent so a later Windows
or shared runtime can replace the panel without changing dictation semantics.

## Packaging

The staged application layout is:

```text
VibeTyping.app/
  Contents/MacOS/VibeTyping
  Contents/Helpers/remote-asr-server
  Contents/Helpers/*.bundle
  Contents/Resources/Pets/default/
```

SwiftPM resource bundles are copied beside the helper because helper execution
resolves `Bundle.main.bundleURL` to `Contents/Helpers`. The build must be tested
from a staged app path; development `.build` fallback paths must not be allowed
to hide a missing bundle.

## Release Gates

- Swift unit tests pass for protocol parsing, state transitions, PCM encoding,
  queue overflow, and both pet atlas versions.
- A staged app contains its helper and every required resource bundle.
- A real local server handshake reaches `session.updated`.
- Twenty consecutive English/Chinese dictations complete without lost audio,
  incorrect target insertion, or an orphaned owned helper process.
