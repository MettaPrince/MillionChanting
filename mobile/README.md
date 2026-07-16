# million_chanting mobile (Flutter)

On-device port of the web app (`../index.html` + `../server.js`): the same
Zipformer Thai model + Silero VAD + matching logic, but running fully on the
phone via the official `sherpa_onnx` Flutter package - no server, no network
round-trip, mic audio never leaves the device. See `../HANDOFF.md` for the
full history of why this exists (server-side concurrency/memory limits on
Render made a mobile-first architecture the better long-term fit).

## One-time setup: copy model assets

The model files aren't committed to this project (same reason as the
server - the int8 encoder is ~147MB, over GitHub's 100MB limit). Before
building, copy them in from the main repo:

```bash
mkdir -p assets/model
cp ../model/encoder-epoch-12-avg-5.int8.onnx \
   ../model/decoder-epoch-12-avg-5.int8.onnx \
   ../model/joiner-epoch-12-avg-5.int8.onnx \
   ../model/tokens.txt \
   ../model/bpe_vocab.txt \
   assets/model/
cp ../silero_vad.onnx assets/
```

## Build

Requires Flutter (stable channel) with Android SDK configured
(`flutter doctor` should show both toolchains green).

```bash
flutter pub get
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk` (~240MB - the
bundled model dominates the size). Install directly on a device via
`adb install <path-to-apk>`, or transfer the file and install manually
(enable "install from unknown sources" if prompted).

On first launch, the app copies the bundled model out of the APK into
app-writable storage (`getApplicationSupportDirectory()`) - this only
happens once; subsequent launches skip it if the files are already there
(same skip-if-present pattern as `../scripts/fetch-model.js`).

## Known simplifications / next steps (first testable build)

- **Decode runs on the main isolate.** `recognizer.decode()` is a
  synchronous native call; for very long chanted segments (the Render logs
  in HANDOFF.md showed decode times climbing past 2s for ~7-8s segments)
  this could cause a brief UI stutter. Moving decode to a background
  isolate is the natural next optimization once basic on-device behavior
  is validated on a real phone - not done yet, to keep this first build
  simpler and faster to ship for testing.
- **Active-line glow animation is simplified.** The web version's
  `siriGlow` CSS keyframe animates a rotating gradient around the active
  line's border; this build uses a static gold/white/gold gradient border
  instead. Same colors, same "active line is visually distinct" effect,
  just without the rotation - a cosmetic polish item, not a functional gap.
- **No custom "Prompt" font bundled** - falls back to the system font.
  The web version loads it from Google Fonts; bundling the same font file
  here is a small follow-up if exact typography match matters.
- **minSdk 24** (`sherpa_onnx_android_*`'s own requirement is 21;
  Flutter's default template constraint is what actually set this). Fine
  for a Galaxy S21 Ultra (ships with Android 11 / API 30+).
