# m-cas

A tape recorder for iPhone. Record a moment and it becomes a clip named for where you were and
when. Every clip on a tape plays as one continuous tape: drag the cassette to wind through it,
forwards or backwards, and hear it as you wind.

iOS port of [BrightRecorder](https://github.com/gi-os/BrightRecorder) for the Light Phone III,
drawn in a dithered 16-color, 15-bit palette.

- **Deck**: tap the cassette to play or stop, hold it to record, drag it to wind. ◀◀ and ▶▶ wind while held.
- **Shelf**: a pile of cassettes. Tap one to load it. + NEW starts a tape.
- **Clips**: the tape runs past the head. Drag to wind, tap a clip to cue it.
- **Label**: pattern, color pair, draw on the label, rename.
- **Action Button**: bind *Record a moment* to start and stop recording.
- **iPhone Duo**: on the inner display the deck stays on the left and the other screens share the right.

Tapes are folders in the app's Files folder, same layout as BrightRecorder:
`tapes/2026-08-17 143205 Trip to Rome/2026-08-17 143912 Trastevere, Rome.wav`

## Build

```sh
brew install xcodegen
xcodegen generate
open MCas.xcodeproj
```

CI: `check.yml` builds and tests every branch unsigned. A push to `main` runs `build.yml`,
which signs with fastlane match (`gi-os/ios-certs`) and uploads to TestFlight. Secrets:
`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `MATCH_PASSWORD`, `MATCH_GIT_AUTH`.

Silkscreen font by Jason Kottke, SIL Open Font License.
