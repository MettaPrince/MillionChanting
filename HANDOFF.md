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
- **public/indexping.html** — an earlier, abandoned prototype using the
  browser's Web Speech API (Google cloud STT) instead of the local model.
  Kept for reference only; **not wired into the current architecture** and
  not being maintained. Ignore unless explicitly asked to revisit it.
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

### Secret note: key.json — URGENT, repo is now public

`key.json` (a GCP service-account key from the abandoned Google STT path) was
committed in the initial commit (`e5ecb17`) and is **still in git history**,
though removed from the current tree and gitignored. **The repo was made
public on 2026-07-15**, so this key is now visible to anyone, including
automated credential-scanning bots that continuously crawl public GitHub
repos. If not already done: **revoke this key in the GCP console
immediately** — that's the step that actually stops misuse; removing it from
git history alone does not (a key committed to a public repo, even briefly,
should be treated as compromised regardless of later history rewrites).
After revoking, scrub it from history with `git filter-repo`/BFG + force-push
if you want it fully gone (not done automatically — ask if you want this
done for you).

## Local scratch files (not part of the repo, informational only)

`C:\catest\`, `C:\chanting-app-dev`, and a few stray files directly under
`C:\Users\Minor\` were created during local isolated testing of the hotwords/
bpeVocab setup. They're outside this project directory and irrelevant to the
Codespace handoff — the local machine owner can clean them up manually
whenever convenient.
