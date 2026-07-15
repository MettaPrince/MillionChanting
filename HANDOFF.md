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

4. **Got a real Render log** (2026-07-15, same day) from an actual test
   session. It showed something more specific and severe than "slow":
   - **RTF was actually fine** (0.27x-0.68x, comfortably under real-time)
     across every decode call. This *disproves* the CPU-starvation-causes-
     slow-decode theory from point 2 above — the 0.1 vCPU is not too weak
     to run this model in real time.
   - But `decodeSegment()` re-decodes the **entire growing buffer from
     scratch** every partial-decode tick (a known, deliberate design
     choice), so decode time climbs as a segment gets longer: one segment's
     ticks went 291ms → 588ms → 795ms → 1002ms → 1288ms → 1601ms →
     **2096ms**, reaching **7.42s of audio** despite `maxSpeechDuration: 6`
     in the VAD config — it should have force-closed at 6s and didn't
     (not yet root-caused; worth checking sherpa-onnx's actual
     `maxSpeechDuration` semantics, or whether the JS-side `speechBuffer`
     preview tracker can drift out of sync with VAD's real segment
     boundary).
   - Right after that 2096ms decode, the service **restarted**
     (`==> Running 'node server.js'`, full ~25s model reload) with no
     redeploy having been triggered. The user then reported Render's own
     failure message directly: **"Exited with status 137"** — exit 137 is
     SIGKILL, and on Render this is the standard signature of an **OOM
     kill**, not a health-check timeout.
   - Investigated why: `decodeSegment()` calls `recognizer.createStream()`
     on *every* decode (partial and final). Confirmed via `strings` on the
     compiled `sherpa-onnx-node` addon that `OfflineStream` **does** have a
     proper N-API finalizer wired to a native destroy function (not a
     hard/permanent leak) — but the addon **never calls
     `napi_adjust_external_memory`** (also confirmed absent from the
     binary), so V8's GC has no signal that native memory is piling up
     behind each stream handle; it only looks at JS heap size, and a stream
     wrapper looks like a near-zero-byte object to it. Frequent stream
     creation (every ~400ms-1s during continuous speech) can plausibly
     outpace how often V8 decides to collect on its own.
   - **Bigger and simpler finding, measured directly in this Codespace**:
     baseline RSS with the model loaded and **zero clients connected** is
     already **~500-523MB** (cross-checked via both Node's own
     `process.memoryUsage()` and the OS `ps` RSS column). Render's free tier
     *and* Starter tier both cap at **512MB RAM** — meaning this app's
     baseline footprint alone is already at or over that ceiling before any
     real usage, which is a much simpler and more direct explanation for an
     OOM kill than the stream-leak nuance above (though that nuance likely
     still contributes on top, under sustained use).
5. **Mitigations applied** (2026-07-15, not yet confirmed against a real
   Render retest):
   - `package.json`: `"start": "node --expose-gc server.js"`.
   - `server.js`: a periodic (`FORCED_GC_INTERVAL_MS`, 20s) forced
     `global.gc()` with before/after RSS + external-memory logging
     (`[gc] RSS ...`), so orphaned native stream handles get reclaimed on a
     bounded schedule instead of waiting on V8's blind heuristics, and so
     the next Render log directly shows whether memory is climbing over a
     session or staying flat.

6. **First forced-GC retest (2026-07-15, same day) showed the flag never
   actually ran.** Render's log showed `[gc] global.gc() not available -
   was the process started without --expose-gc?` right at boot, and the
   boot line itself read `Running 'node server.js'` — not
   `node --expose-gc server.js`. This means Render's dashboard has a
   **manually-configured Start Command that overrides package.json's
   `"start"` script entirely** — editing `package.json`/`render.yaml` alone
   does not reach an already-existing (non-Blueprint-deployed) Render
   service. So the forced-GC mitigation was never actually tested by that
   retest.
   That same log ended with Render's own explicit, unambiguous message:
   **"Ran out of memory (used over 512MB)"** — this fully **confirms** the
   RAM-ceiling theory from point 4, no longer inferred from exit codes.
   It also showed memory growth happening progressively *during* a session
   (the service ran successfully for ~63 seconds, processing several
   decode segments, before finally crossing the limit) — consistent with
   the native-stream GC-blind-spot theory actively contributing on top of
   the tight baseline, not just a static baseline-alone problem.
   **Fix applied**: switched from relying on the `"start"` script's CLI
   flag to a `NODE_OPTIONS=--expose-gc` env var (`render.yaml`), which is
   picked up by any `node` invocation regardless of the exact start
   command string — verified locally that this works even without an
   explicit `--expose-gc` flag on the command line. **But this still
   requires a manual step**: `render.yaml` only applies to new
   Blueprint-created services; for an existing dashboard-configured
   service, `NODE_OPTIONS=--expose-gc` must be added directly under that
   service's Render dashboard → Environment tab, then redeployed. Confirm
   from the next boot log that `global.gc() not available` does *not*
   appear before trusting any `[gc]` numbers that follow.

**Not yet done / next step:** after adding `NODE_OPTIONS=--expose-gc` in
Render's dashboard Environment tab and redeploying, retest and watch for
`[gc]` log lines over a longer session (is RSS climbing or flat?) and
whether an OOM recurs. If baseline RSS really is at Render's ceiling,
forced GC alone may not be enough — the more direct fix is a plan with more
RAM. **Note this changes the earlier tier recommendation**: Starter
($7/mo) only adds CPU (0.5 vCPU) and keeps the *same* 512MB RAM as free, so
it would not fix a RAM-ceiling problem. **Standard ($25/mo) is the one that
adds RAM** (2GB, plus 1 vCPU) and is the tier to consider if the
baseline-memory theory holds up even with forced GC in place. Reducing
server-side decode frequency/cost (e.g. the 400ms
`PARTIAL_DECODE_INTERVAL_MS`, or `maxActivePaths`) remains a free
alternative/complement, but trades away some of the deliberately-tuned
"live" responsiveness described under Real-time matching design above — get
the project owner's sign-off before changing those.

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
