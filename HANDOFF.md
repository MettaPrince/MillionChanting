# Handoff — chanting-app (sherpa-onnx local ASR pipeline)

Thai Buddhist katha (mantra) chanting webapp. Live speech recognition confirms
the user chanted each of 12 katha lines in order, advancing a gold-outline
"katha viewer" UI and counting completed loops. Free public deploy on
Render.com for a charity, primary target is mobile Chrome.

## Architecture

- **server.js** — Express + Socket.IO. Receives raw 16-bit PCM audio chunks
  from the browser over a socket, runs it through a Silero VAD to segment
  continuous audio into utterances, then decodes each segment with
  **sherpa-onnx-node**'s `OfflineRecognizer` (Zipformer transducer, Thai,
  int8-quantized). Emits `'transcript-partial'` (live re-decode of the
  still-open segment, every 400ms) and `'transcript'` (final, once VAD closes
  the segment) back to the client.
- **index.html** (served at `/`) — the active frontend. Captures mic audio,
  streams it to the server, and matches decoded text against per-line trigger
  words to advance the UI in real time. This is the file to keep iterating on.
- Mic capture in index.html uses `ScriptProcessorNode`
  (`createScriptProcessor`) to get raw PCM out of the Web Audio graph for
  downsample-to-16kHz + Float32→Int16 encoding, then emits chunks over the
  socket. **AudioWorkletNode was tried and reverted on 2026-07-15** (moving
  that same work to `public/pcm-worklet-processor.js` on a dedicated
  audio-rendering thread, to fix a mobile capture-lag report) — but testing
  showed it captured **worse** than the ScriptProcessorNode version even on
  localhost with a full CPU available, which localhost had never had a
  problem with before. That means whatever went wrong wasn't the
  CPU-contention theory the migration was meant to fix; there's a real,
  not-yet-diagnosed bug specific to the AudioWorkletNode implementation
  (or how this app wired it up) that made it strictly worse, not just
  ineffective. Don't re-attempt this migration without first understanding
  *why* it regressed — re-adding the same worklet code blind will very
  likely reproduce the same regression. The file was deleted; if picking
  this back up, `git show 394d3c5:public/pcm-worklet-processor.js` has the
  old implementation for reference, and `git show 394d3c5 -- index.html`
  has how it was wired in.
  Separately (and still true regardless of the above): the abandoned Web
  Speech API prototype (`public/indexping.html`, mentioned in older notes,
  no longer in the repo) never had a capture-lag problem at all, because
  `MediaRecorder` encodes audio natively with no manual JS sample
  processing — but it also can't produce the raw PCM the local ASR model
  needs, so it isn't an option here regardless of this ScriptProcessor
  vs. AudioWorklet question.
- **model/** — Thai Zipformer transducer model files + Silero VAD model
  (`silero_vad.onnx`, project root). Both int8 and full-precision encoder
  files are present locally; **only the int8 files are used** by server.js
  (`encoder/decoder/joiner-epoch-12-avg-5.int8.onnx`).

## Why sherpa-onnx (not Web Speech API)

Web Speech API (browser/Google cloud STT) was built out and hardened first,
but was rejected for production after extensive testing showed intermittent
silent backend stalls (10s-90s gaps with no transcript, no error) under
sustained multi-hour use, which is unacceptable for a chanting session. This
was a deliberate, evidence-based decision — don't revert to it without cause.

## Real-time matching design (the core, most-iterated piece)

`advanceMatching(text, isFinal)` in index.html is fed by **both**
`'transcript-partial'` and `'transcript'` through the same persistent cursor
(`sessionMatchCursor`) and matching pass — this is what makes the gold
outline move line-by-line in real time instead of waiting for a whole
segment to finish. For each newly revealed stretch of text, it checks up to
`maxLookahead = 3` lines ahead of the current line, in order, and takes the
**first line (not necessarily earliest text position)** whose trigger word
appears anywhere in the remaining text (`findFirstMatch` in index.html).

**Known, understood tradeoff (not a bug to "fix" casually):** because
`transcript-partial` re-decodes the same growing audio buffer from scratch
every 400ms, an early partial can transiently render a stretch of audio
differently than the eventual fuller decode — and once a match consumes the
cursor, it can't be undone. This has been directly confirmed twice in
testing (a partial matched "พุทธะ" and "โคนา" that never actually appeared in
the settled final transcript). `maxLookahead` acts as a safety net when this
causes a skipped line. A stricter "confirm on next decode before committing"
fix was proposed and explicitly declined by the project owner — current
behavior is accepted as-is. Don't re-litigate this without new evidence.

## Hotwords / contextual biasing (server.js)

`CONFIRMED_TRIGGER_WORDS` (server.js, ~line 86) is a curated allow-list of
trigger words that get an aggressive hotword boost
(`CONFIRMED_TRIGGER_WORD_SCORE = 8.0`) via sherpa-onnx's `createStream(hotwords)`.
**Only add words here once they've been seen correctly transcribed in a real
chanting test** — an earlier uniform boost of the entire `triggerWords` list
measurably made transcription *worse* (contextual biasing reweights beam
search, it can't teach the acoustic model a sound it doesn't recognize, and
boosting short/generic substrings caused hallucinations into unrelated
audio). Keep growing this set from real evidence only.

**Known drift:** `KATHA_LINES` in server.js (~line 53) is a **manually
duplicated copy** of `kathaLines` in index.html (text + triggerWords, no
`desc`), used only to build the hotwords list — it is **not** used for
client-side line-advancement logic, so drift doesn't break matching, only
means some words the client now uses aren't hotword-boosted yet (or vice
versa). It has already drifted (e.g. index.html recently had `"พุทธะ"`
removed from line 7's triggerWords; server.js's copy still has it, though it
was never in `CONFIRMED_TRIGGER_WORDS` so this specific case is harmless).
Re-sync manually whenever kathaLines changes meaningfully and you want new
words hotword-boosted.

## UI conventions to preserve

- Version number in the `<h1>` (`พระคาถาเงินล้านv1.NN`) is bumped after every
  meaningful change, purely so changes are visually confirmable after a
  deploy/refresh. Keep doing this.
- The katha viewer is a 3-panel CSS carousel (`#kathaSlider`, `.katha-page`,
  a hidden `#page1Clone` panel) that always slides forward
  (left) — including on loop wraparound, which slides into the invisible
  clone then snaps back instantly. Never let a loop wrap flip backward.
- Advancement is driven **only** by real, confirmed keyword matches — no
  speculative/preview animation, no batching multiple lines then animating
  through them. This was explicitly reverted twice earlier in the project;
  don't reintroduce a "preview" mechanism.
- Colors: completed lines = gold (`var(--gold)`), active line = animated gold
  outline, matched trigger-word highlights in the debug transcript = green.

## Known ASR-quirk mitigations already in place

- `HALLUCINATION_PHRASES` (server.js, `decodeSegment`) strips known filler
  hallucinations (currently just `"เพลง"`) from decoded text before it's
  matched or displayed — the model outputs this on quiet/ambiguous audio
  (e.g. mic warm-up before the very first chant), not real content.
- Silero VAD `threshold: 0.6` / `minSpeechDuration: 0.35` (server.js
  `vadConfig`) were raised from defaults (0.5 / 0.2) specifically to stop
  short noise/breath blips from opening a false segment that then blends
  with real speech and produces a garbled/hallucinated decode.

## Capture-lag investigation (ongoing, opened 2026-07-15)

Reported symptom: chanting on mobile felt slower/more delayed than on a
laptop. Investigation so far, in order:

1. Suspected `ScriptProcessorNode`'s main-thread `onaudioprocess` callback
   competing with UI work on mobile's tighter CPU budget. Migrated to
   `AudioWorkletNode` to move that work off the main thread. **Reverted** —
   see the AudioWorkletNode note under Architecture above; it made capture
   *worse*, even on localhost, which points at a real bug in that
   implementation rather than confirming/denying the original theory.
2. Confirmed Render's free tier is **0.1 vCPU / 512MB RAM** (real number,
   not an assumption — see sources in the conversation this was resolved
   in). Both a laptop and a phone were reported slow when hitting the same
   deployed Render URL, while a laptop hitting **localhost** was fine — that
   rules out "mobile-specific" as the sole cause and points at Render's
   server-side compute being the bottleneck for everyone.
   `recognizer.decode()` in `decodeSegment()` (server.js) is a synchronous
   native call that blocks Node's single event loop thread for its full
   duration; on a CPU-starved host a slow decode also delays every queued
   audio-chunk and the partial-decode timer behind it.
3. Added diagnostics, still in place, not yet reviewed against a real
   Render+phone test:
   - server.js: logs `[decode] Xs audio in Yms (RTF Z x)` per decode call —
     RTF (real-time factor) consistently above 1 on Render would confirm
     the CPU-starvation theory directly.
   - server.js: a `client-ping`/`client-pong` immediate echo (before any
     VAD/decode work), so round-trip network latency can be measured
     separately from ASR compute time.
   - server.js: recognizer `numThreads` dropped 2 → 1 to match the
     confirmed 0.1 vCPU allocation (a second thread has no spare core to
     run on there).
   - index.html: the "Debug Monitor" panel (already in the UI, tap to
     expand) has new rows showing the negotiated Socket.IO transport
     (`websocket` vs. a mobile network falling back to HTTP long-polling —
     the latter adds a full request/response round-trip per message and is
     a classic hidden mobile-specific lag source), live ping RTT, a running
     sent-chunk counter, and a capture status/error indicator.

**Not yet done / next step:** a real phone test against the actual Render
deployment, with the Debug Monitor panel open, plus checking Render's logs
for the RTF numbers. That data should say definitively whether this is
CPU-starvation, transport fallback, both, or something not yet considered
— rather than guessing a fourth fix blind. Once diagnosed, the two
known remediation paths (should the CPU-starvation theory hold) are: (a)
upgrade Render's plan (Starter $7/mo = 0.5 vCPU, Standard $25/mo = 1 vCPU +
2GB RAM — pure cost, no UX tradeoff), or (b) reduce server-side decode
frequency/cost (e.g. the 400ms `PARTIAL_DECODE_INTERVAL_MS`, or
`maxActivePaths`) — free, but trades away some of the deliberately-tuned
"live" responsiveness described under Real-time matching design above, so
don't change those without the project owner's sign-off.

## Deployment status (updated 2026-07-15, Codespace session)

Most blockers below are now **RESOLVED**. Remaining runtime tuning noted at
the end.

1. ~~No git repo~~ **DONE** — repo exists and is pushed to
   `github.com/MettaPrince/MillionChanting` (**public**, changed from private
   2026-07-15 — see secret note below, this matters).
2. ~~No `.gitignore`~~ **DONE** — excludes `node_modules`, `key.json`, the
   large int8 encoder (fetched at build), the unused full-precision `*.onnx`
   weights, and `model/test_wavs/`.
3. **Model file size vs GitHub's 100MB limit** — **RESOLVED via
   download-at-build:**
   - The int8 encoder (`model/encoder-epoch-12-avg-5.int8.onnx`, ~147MB) is
     **NOT committed**. It's uploaded as a release asset on this repo
     (`models-v1` release) and pulled at build time by
     [scripts/fetch-model.js](scripts/fetch-model.js), wired as `postinstall`
     in package.json.
   - Repo is now **public**, so the release asset downloads anonymously — no
     token/auth needed. `scripts/fetch-model.js` just does a plain HTTPS GET
     on the public release-asset URL. See [render.yaml](render.yaml).
   - Full-precision `*.onnx` weights (~600MB encoder etc.) are gitignored and
     unused. `decoder`/`joiner` int8, `tokens.txt`, `bpe_vocab.txt`,
     `bpe.model`, and root `silero_vad.onnx` are small and committed directly.
   - To publish a new encoder: `gh release upload models-v1
     model/encoder-epoch-12-avg-5.int8.onnx --clobber`.
4. ~~No `start` script~~ **DONE** — `"start": "node server.js"` added. The
   native sherpa-onnx addon resolves its shared libs on its own on this
   Linux/Codespace image (no `LD_LIBRARY_PATH` needed); if a future Render
   image can't find them, prepend
   `LD_LIBRARY_PATH=$(npm root)/sherpa-onnx-node/lib`.
5. **`BPE_VOCAB_PATH`** — Windows-only; not set on Render (code defaults to
   `model/bpe_vocab.txt`). No action needed.
6. ~~Unused `@google-cloud/speech` dependency~~ **DONE** — removed from
   package.json + lockfile.
7. **Memory/CPU on Render free tier** — still worth watching once deployed.
   int8 model chosen for this reason; `numThreads` is 2 (recognizer) / 1
   (VAD) in server.js — tune down if memory/CPU-constrained.

### Secret note: key.json — scrubbed from history 2026-07-15

`key.json` (a GCP service-account key from the abandoned Google STT path) was
committed in the initial commit and briefly visible in the public repo. It
has since been fully removed via `git filter-repo` + a force-push to
`origin/main` (and the `models-v1` tag, whose commit hash also shifted) —
verified gone from every commit/branch via a fresh clone and a full object
scan. **All commit hashes changed** as a result; if anyone else ever cloned
this repo before 2026-07-15, their clone has now diverged and needs a fresh
clone or a hard reset to the new history.

This only removes the key from git — it does **not** revoke the credential
itself. Since the key was exposed on a public repo (even briefly), **treat it
as compromised and revoke it in the GCP console** if that hasn't been done
already; a history scrub alone doesn't invalidate a key that may have already
been scraped.

## Local scratch files (not part of the repo, informational only)

`C:\catest\`, `C:\chanting-app-dev`, and a few stray files directly under
`C:\Users\Minor\` were created during local isolated testing of the hotwords/
bpeVocab setup. They're outside this project directory and irrelevant to the
Codespace handoff — the local machine owner can clean them up manually
whenever convenient.
