const express = require('express');
const path = require('path');
const app = express();
const http = require('http').createServer(app);
const io = require('socket.io')(http, {
    maxHttpBufferSize: 1e7,
});

// sherpa-onnx-node is the official Node.js native-addon package for sherpa-onnx.
// npm install sherpa-onnx-node express socket.io
//
// NOTE: the native addon needs its shared libraries discoverable at runtime.
// Linux:   export LD_LIBRARY_PATH=$(npm root)/sherpa-onnx-node/lib:$LD_LIBRARY_PATH
// macOS:   export DYLD_LIBRARY_PATH=$(npm root)/sherpa-onnx-node/lib:$DYLD_LIBRARY_PATH
// Windows: the addon ships its own .dll next to the .node file, no env var needed.
const sherpa_onnx = require('sherpa-onnx-node');

// ----------------------------------------------------------------------------
// IMPORTANT - read this before running:
//
// "sherpa-onnx-zipformer-thai-2024-06-20" (no "streaming" in the name) is an
// OFFLINE / non-streaming model - k2-fsa has not published a streaming Thai
// model. Feeding it into OnlineRecognizer fails with an error like:
//   "encoder_dims does not exist in the metadata"
// because that error comes from the code path that only understands
// streaming-zipformer2 encoders.
//
// So this server uses:
//   1. OfflineRecognizer  - runs the Thai model, but only on a complete chunk
//      of audio handed to it all at once (it can't be fed live sample by
//      sample like a streaming model).
//   2. Silero VAD (bundled with sherpa-onnx) - listens to the continuous mic
//      stream and cuts it into "one segment = one pause-to-pause utterance"
//      chunks, each of which gets handed to the OfflineRecognizer above.
//
// You still get "no 60s cutoff", just with slightly chunkier (per-phrase
// rather than per-syllable) updates instead of a smoothly growing live
// transcript. Download the VAD model with:
//   wget https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
// and place it next to this file (or update SILERO_VAD_PATH below).
// ----------------------------------------------------------------------------

const MODEL_DIR = path.join(__dirname, 'model');
const SILERO_VAD_PATH = path.join(__dirname, 'silero_vad.onnx');

// The katha vocabulary this app is trying to recognize - Pali/Sanskrit
// mantra syllables that are essentially out-of-vocabulary for a Thai ASR
// model trained on ordinary conversational/read speech. Used below to build
// a hotwords list (contextual biasing) so the decoder is nudged toward
// outputting one of these known-good/known-misheard spellings instead of
// whatever unrelated Thai word it would otherwise guess. Keep this in sync
// with the kathaLines array in index.html if that ever changes.
const KATHA_LINES = [
    { text: "สัมปะจิตฉามิ", triggerWords: ["สัมปะจิตฉามิ", "สัมปจิตฉามิ", "สัมปะจิชฌามิ", "จิชฌามิ", "ปะจิตฉา"] },
    { text: "นาสังสิโม", triggerWords: ["สังสิโม"] },
    { text: "พรัหมา จะ มหาเทวา สัพเพยักขา ปะลายันติ", triggerWords: ["สัพเพยักขา", "ปะรายันติ", "ยันติ"] },
    { text: "พรัหมา จะ มหาเทวา อภิลาภา ภะวันตุ เม", triggerWords: ["อภิลาภา", "ภิลาภะ", "ภิลาภา", "ภะวันตุเม"] },
    { text: "มหาปุญโญ มหาลาโภ ภะวันตุ เม", triggerWords: ["ปุญโญ", "ปุนโย", "ลาโภ"] },
    { text: "มิเตพาหุหะติ", triggerWords: ["มิเต", "มีเต", "ภาหุ", "หุหะ", "หะติ", "หุหะติ", "หูหะ"] },
    { text: "พุทธะมะอะอุ นะโมพุทธายะ", triggerWords: ["พุทธะ", "มะอะอุ", "นะโม", "พุทธายะ", "ทายะ", "ท้ายะ"] },
    { text: "วิระทะโย วิระโคนายัง วิระหิงสา", triggerWords: ["ทะโย", "ทาโย", "โคนา", "หิงสา", "อิงสา"] },
    { text: "วิระทาสี วิระทาสา วิระอิตถิโย", triggerWords: ["ทาสี", "ทาสา", "อิตถิ", "ถิโย"] },
    { text: "พุทธัสสะ มานีมามะ พุทธัสสะ สวาโหม", triggerWords: ["มานี", "มามะ", "สวา", "สะหวา", "สวาโหม", "วาโหม", "โหม"] },
    { text: "สัมปะติจฉามิ", triggerWords: ["สัมปะติ", "ปะติฉา", "ติจฉามิ"] },
    { text: "เพ็งเพ็ง พาพา หาหา ฤๅฤๅ", triggerWords: ["หา", "ฤ", "ฤๅ", "ลือ", "รือ"] },
];

// createStream(hotwords) expects phrases separated by '/', optionally with
// a per-phrase boost score like 'word :2.0/otherword'. Contextual biasing
// only re-weights which hypotheses win in the decoder's beam search - it
// can't teach the acoustic model a sound it has near-zero confidence in to
// begin with, so boosting a genuinely unrecognizable syllable has
// diminishing/negative returns (an earlier uniform :8-10 on the whole
// triggerWords list measurably made transcription worse, not better - it
// wasn't just boosting good words, it was also making the model hallucinate
// every generic short substring into unrelated audio).
//
// Length was tried as a filter and was the wrong proxy - short words like
// "หา" turned out to be reliably recognized. The signal that actually works
// is real evidence: only words that have shown up correctly-transcribed in
// an actual chanting test get the aggressive boost below. Everything else
// in triggerWords is still used for post-hoc fuzzy matching in index.html,
// just left out of ASR-level hotwords until it's proven too. Grow this set
// as more words get confirmed through testing - don't just add speculative
// ones back in.
const CONFIRMED_TRIGGER_WORDS = new Set([
    'สังสิโม', 'ยันติ', 'มิเต', 'พุทธายะ', 'อิงสา', 'ทาสา', 'มามะ', 'หา',
    'ปะจิตฉา', 'ปุนโย', 'อภิลาภา', 'โคนา',
]);

const CONFIRMED_TRIGGER_WORD_SCORE = 8.0;
const CANONICAL_TEXT_HOTWORD_SCORE = 6.0;

const hotwordScores = new Map();
function addHotword(phrase, score) {
    const existing = hotwordScores.get(phrase);
    if (existing === undefined || score > existing) hotwordScores.set(phrase, score);
}
KATHA_LINES.forEach(line => {
    addHotword(line.text, CANONICAL_TEXT_HOTWORD_SCORE);
    line.triggerWords
        .filter(w => CONFIRMED_TRIGGER_WORDS.has(w))
        .forEach(w => addHotword(w, CONFIRMED_TRIGGER_WORD_SCORE));
});
const HOTWORDS = Array.from(hotwordScores.entries())
    .map(([phrase, score]) => `${phrase} :${score}`)
    .join('/');

// Double-check these filenames against what's actually inside MODEL_DIR -
// offline model releases are sometimes "encoder-epoch-XX-avg-Y.onnx" and
// sometimes "encoder.onnx" / "encoder.int8.onnx" depending on the release.
const offlineRecognizerConfig = {
    featConfig: {
        sampleRate: 16000,
        featureDim: 80,
    },
    modelConfig: {
        transducer: {
            // int8-quantized: ~150MB vs ~600MB for the full-precision
            // files - matters a lot for a memory-capped Render.com host,
            // and decodes noticeably faster too.
            encoder: path.join(MODEL_DIR, 'encoder-epoch-12-avg-5.int8.onnx'),
            decoder: path.join(MODEL_DIR, 'decoder-epoch-12-avg-5.int8.onnx'),
            joiner: path.join(MODEL_DIR, 'joiner-epoch-12-avg-5.int8.onnx'),
        },
        tokens: path.join(MODEL_DIR, 'tokens.txt'),
        // Required for hotwords/contextual biasing to accept plain Thai
        // words (rather than raw token-id sequences) in createStream().
        // NOTE: bpeVocab wants a plain-text "piece score" listing, not the
        // raw binary sentencepiece bpe.model - bpe_vocab.txt was generated
        // from bpe.model via sentencepiece (see scratchpad/dump_bpe_vocab.py
        // used during setup) and checked into model/ alongside it.
        //
        // BPE_VOCAB_PATH env override: this addon's bpeVocab loader opens
        // the file via a Windows ANSI-codepage call internally, which can't
        // represent non-ASCII path characters - breaks if this project sits
        // under a Unicode folder name (e.g. a Thai "Desktop"), even though
        // every other model file loads fine from the same path. Doesn't
        // affect Linux deploys (Render), only local Windows dev under a
        // Unicode path. Set BPE_VOCAB_PATH to an ASCII-path copy of
        // bpe_vocab.txt to work around it locally.
        modelingUnit: 'bpe',
        bpeVocab: process.env.BPE_VOCAB_PATH || path.join(MODEL_DIR, 'bpe_vocab.txt'),
        // Render's free tier allocates 0.1 vCPU (a tenth of one core) - there
        // is no spare core for a second thread to actually run on, so 2
        // threads here only adds OS scheduling/context-switch overhead on
        // that host, not real parallelism. 1 matches the actual available
        // compute; revisit only if this ever runs on a host with >=1 real CPU.
        numThreads: 1,
        provider: 'cpu',
        debug: false,
        // NOTE: no modelType here on purpose - forcing "zipformer2" is what
        // broke the streaming attempt. The offline transducer loader doesn't
        // need this hint.
    },
    // modified_beam_search (not greedy_search) is required for hotwords
    // support - greedy search has no mechanism to bias toward a vocabulary.
    decodingMethod: 'modified_beam_search',
    maxActivePaths: 4,
};

const vadConfig = {
    sileroVad: {
        model: SILERO_VAD_PATH,
        // Raised from 0.5: at 0.5, a short blip of mic noise/breath (most
        // common right at the very start, before the user is chanting
        // loudly) can cross the bar and open a segment on its own. If real
        // speech then follows before the segment closes, the two get
        // decoded together and the model can hallucinate on the whole blob
        // (e.g. "เพลง") instead of transcribing the real words - so the
        // fix belongs here, not as a text filter on the output.
        threshold: 0.6,
        // How much silence ends a chant phrase/line and closes the segment.
        // Lower = cuts more eagerly on short pauses between lines, trading
        // transcription accuracy (less context per segment) for lower
        // feedback latency.
        minSilenceDuration: 0.35,
        // Raised from 0.2s: real chanted syllables/phrases run well over
        // this, so requiring a bit more sustained voicing before a segment
        // is allowed to open filters out brief noise/breath blips without
        // cutting into real speech.
        minSpeechDuration: 0.35,
        // Safety valve so one long uninterrupted chanting stretch still gets
        // cut into decodable pieces instead of growing forever/waiting for a
        // pause that may not come for many seconds.
        maxSpeechDuration: 6,
        windowSize: 512,
    },
    sampleRate: 16000,
    numThreads: 1,
    provider: 'cpu',
    debug: false,
    bufferSizeInSeconds: 30,
};

console.log('Loading sherpa-onnx offline model from', MODEL_DIR, '...');
let recognizer;
try {
    recognizer = new sherpa_onnx.OfflineRecognizer(offlineRecognizerConfig);
    console.log('ASR model loaded OK.');
} catch (err) {
    console.error('Failed to load the sherpa-onnx ASR model. Check the paths in MODEL_DIR / offlineRecognizerConfig above.');
    console.error(err);
    process.exit(1);
}

function createVad() {
    try {
        return new sherpa_onnx.Vad(vadConfig);
    } catch (err) {
        console.error('Failed to load the Silero VAD model. Check SILERO_VAD_PATH above.');
        console.error(err);
        return null;
    }
}

// Sanity-check the VAD model loads before accepting any connections.
const vadSanityCheck = createVad();
if (!vadSanityCheck) {
    process.exit(1);
}
if (typeof vadSanityCheck.free === 'function') vadSanityCheck.free();

// ----------------------------------------------------------------------------
// Periodic forced GC - works around a native-addon memory-growth pattern.
//
// decodeSegment() below calls recognizer.createStream() on every decode,
// including the live partial-preview one firing every ~400ms-1s during
// continuous speech. sherpa-onnx-node's OfflineStream wraps a native
// SherpaOnnxOfflineStream pointer with a proper N-API finalizer (confirmed
// via `strings` on the compiled addon - SherpaOnnxDestroyOfflineStream is
// wired up), so this isn't a hard/permanent leak. But the addon never calls
// napi_adjust_external_memory to tell V8 how much native memory each handle
// actually holds (also confirmed via `strings` - that symbol isn't present
// anywhere in the binary) - V8's GC scheduling only looks at JS heap size,
// and each stream wrapper looks like a near-zero-byte object to it, so V8
// has no signal to collect promptly even as native memory piles up behind
// many short-lived handles. On Render's 512MB free tier this can plausibly
// exhaust memory and trigger an OOM kill (exit code 137, confirmed from a
// real Render log) well before V8 would have gotten around to a GC pass on
// its own. Forcing a GC pass periodically (requires --expose-gc, see
// package.json's "start" script) reclaims those orphaned native-memory
// handles on a bounded schedule instead of leaving it to V8's blind spot.
// Logs memory before/after so this can be confirmed/tuned from Render logs.
// ----------------------------------------------------------------------------
const FORCED_GC_INTERVAL_MS = 20 * 1000;
if (typeof global.gc === 'function') {
    setInterval(() => {
        const before = process.memoryUsage();
        global.gc();
        const after = process.memoryUsage();
        console.log(
            `[gc] RSS ${(before.rss / 1e6).toFixed(0)}MB -> ${(after.rss / 1e6).toFixed(0)}MB, ` +
            `external ${(before.external / 1e6).toFixed(0)}MB -> ${(after.external / 1e6).toFixed(0)}MB`
        );
    }, FORCED_GC_INTERVAL_MS);
} else {
    console.warn('[gc] global.gc() not available - was the process started without --expose-gc?');
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------
function pcm16ToFloat32(int16Array) {
    const float32Array = new Float32Array(int16Array.length);
    for (let i = 0; i < int16Array.length; i++) {
        float32Array[i] = int16Array[i] / 32768.0;
    }
    return float32Array;
}

// Buffer.byteOffset into its underlying ArrayBuffer isn't always a multiple
// of 2 (Node pools small allocations at arbitrary offsets), so Int16Array
// can throw "start offset ... should be a multiple of 2". DataView has no
// such alignment requirement, so read the little-endian int16 samples
// through it instead.
function bufferToInt16Array(buf) {
    const length = Math.floor(buf.byteLength / 2);
    const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
    const result = new Int16Array(length);
    for (let i = 0; i < length; i++) {
        result[i] = view.getInt16(i * 2, true);
    }
    return result;
}

// The model sometimes hallucinates common filler words on quiet/ambiguous
// audio (e.g. mic warm-up noise before the very first chant) instead of
// staying silent. These are never real chanting, so strip them unconditionally
// before the text is matched or shown to the user.
const HALLUCINATION_PHRASES = ['เพลง'];

function stripHallucinations(text) {
    let cleaned = text;
    for (const phrase of HALLUCINATION_PHRASES) {
        cleaned = cleaned.split(phrase).join('');
    }
    return cleaned;
}

// Run the (comparatively slow, non-streaming) ASR model on one finished
// speech segment and return its text.
//
// Logs a real-time factor (RTF) for every decode: wall-clock decode time
// divided by the audio's own duration. RTF > 1 means decode is slower than
// real time - on a CPU-starved host (e.g. Render free tier's 0.1 vCPU) this
// is the mechanism that causes growing lag: recognizer.decode() below is a
// synchronous native call that blocks Node's single event loop thread for
// its full duration, so a slow decode also delays every queued audio-chunk
// and the partial-decode timer behind it, not just this one call.
function decodeSegment(samples) {
    const stream = recognizer.createStream(HOTWORDS);
    stream.acceptWaveform({ samples, sampleRate: 16000 });

    const audioSeconds = samples.length / 16000;
    const decodeStart = Date.now();
    recognizer.decode(stream);
    const decodeMs = Date.now() - decodeStart;
    const rtf = audioSeconds > 0 ? (decodeMs / 1000 / audioSeconds) : 0;
    console.log(`[decode] ${audioSeconds.toFixed(2)}s audio in ${decodeMs}ms (RTF ${rtf.toFixed(2)}x)`);

    // Different sherpa-onnx-node versions expose the result slightly
    // differently - support both shapes defensively.
    let result = null;
    if (typeof recognizer.getResult === 'function') {
        result = recognizer.getResult(stream);
    } else if (stream.result) {
        result = stream.result;
    }
    const rawText = result && typeof result.text === 'string' ? result.text : '';
    return stripHallucinations(rawText);
}

// ----------------------------------------------------------------------------
// Socket.io wiring
// ----------------------------------------------------------------------------
// How often to re-decode the in-progress utterance for a live preview.
// The full-precision encoder is comparatively slow, so this is deliberately
// conservative - if previews start lagging behind real time, switch
// offlineRecognizerConfig above to the int8 model files in MODEL_DIR.
const PARTIAL_DECODE_INTERVAL_MS = 400;
const PARTIAL_DECODE_MIN_SAMPLES = 0.3 * 16000; // don't bother decoding <0.3s

io.on('connection', (socket) => {
    let vad = null;
    // Leftover samples that didn't fill a full VAD window (512 samples) yet.
    let pending = new Float32Array(0);
    // All samples belonging to the utterance currently in progress (reset
    // whenever the VAD transitions from silence to speech, or a segment
    // finalizes). Used only for the live preview below - the authoritative
    // audio for the real 'transcript' event still comes from vad.front().
    let speechBuffer = new Float32Array(0);
    let wasDetected = false;
    let partialTimer = null;

    console.log('Client connected:', socket.id);

    // Immediate echo, deliberately before any VAD/decode work, so the client
    // can measure pure transport round-trip time separate from ASR compute
    // time - lets the Debug Monitor panel tell network latency apart from a
    // slow/backed-up decode.
    socket.on('client-ping', (sentAt) => {
        socket.emit('client-pong', sentAt);
    });

    socket.on('start-audio', () => {
        if (vad && typeof vad.free === 'function') vad.free();
        vad = createVad();
        pending = new Float32Array(0);
        speechBuffer = new Float32Array(0);
        wasDetected = false;
        if (!vad) {
            socket.emit('server-error', 'ไม่สามารถเริ่มต้นระบบตรวจจับเสียงพูด (VAD) ได้');
            return;
        }
        console.log(`[${socket.id}] VAD started`);

        if (partialTimer) clearInterval(partialTimer);
        partialTimer = setInterval(() => {
            if (!vad || speechBuffer.length < PARTIAL_DECODE_MIN_SAMPLES) return;
            const text = decodeSegment(speechBuffer);
            if (text && text.trim().length > 0) {
                socket.emit('transcript-partial', text);
            }
        }, PARTIAL_DECODE_INTERVAL_MS);
    });

    // arrayBuffer: raw 16-bit signed PCM, mono, 16kHz, little-endian.
    socket.on('audio-chunk', (arrayBuffer) => {
        if (!vad) return;

        try {
            const buf = Buffer.isBuffer(arrayBuffer) ? arrayBuffer : Buffer.from(arrayBuffer);
            const int16Samples = bufferToInt16Array(buf);
            const float32Samples = pcm16ToFloat32(int16Samples);

            // Stitch onto whatever was left over from the previous chunk.
            const combined = new Float32Array(pending.length + float32Samples.length);
            combined.set(pending, 0);
            combined.set(float32Samples, pending.length);

            const windowSize = vadConfig.sileroVad.windowSize;
            let offset = 0;
            while (offset + windowSize <= combined.length) {
                vad.acceptWaveform(combined.subarray(offset, offset + windowSize));
                offset += windowSize;
            }
            pending = combined.subarray(offset);

            // Track the audio for whatever utterance is currently in
            // progress, so the preview timer has something to re-decode.
            const nowDetected = vad.isDetected();
            if (nowDetected && !wasDetected) {
                speechBuffer = new Float32Array(0);
            }
            if (nowDetected) {
                const merged = new Float32Array(speechBuffer.length + float32Samples.length);
                merged.set(speechBuffer, 0);
                merged.set(float32Samples, speechBuffer.length);
                speechBuffer = merged;
            }
            wasDetected = nowDetected;

            while (!vad.isEmpty()) {
                const segment = vad.front();
                vad.pop();
                speechBuffer = new Float32Array(0);
                wasDetected = false;
                if (segment && segment.samples && segment.samples.length > 0) {
                    const text = decodeSegment(segment.samples);
                    console.log(`[${socket.id}] decoded: "${text}"`);
                    if (text && text.trim().length > 0) {
                        socket.emit('transcript', text);
                    }
                }
            }
        } catch (err) {
            console.error(`[${socket.id}] error processing audio chunk:`, err);
        }
    });

    socket.on('stop-audio', () => {
        if (!vad) return;
        try {
            // Flush anything still sitting in the VAD's buffer as a final
            // segment, in case the user stopped mid-phrase.
            while (!vad.isEmpty()) {
                const segment = vad.front();
                vad.pop();
                if (segment && segment.samples && segment.samples.length > 0) {
                    const text = decodeSegment(segment.samples);
                    if (text && text.trim().length > 0) {
                        socket.emit('transcript', text);
                    }
                }
            }
        } catch (err) {
            console.error(`[${socket.id}] error finishing up:`, err);
        } finally {
            if (partialTimer) { clearInterval(partialTimer); partialTimer = null; }
            if (vad && typeof vad.free === 'function') vad.free();
            vad = null;
            pending = new Float32Array(0);
            speechBuffer = new Float32Array(0);
            wasDetected = false;
            console.log(`[${socket.id}] VAD stopped`);
        }
    });

    socket.on('disconnect', () => {
        if (partialTimer) { clearInterval(partialTimer); partialTimer = null; }
        if (vad && typeof vad.free === 'function') vad.free();
        vad = null;
        console.log('Client disconnected:', socket.id);
    });
});

// ----------------------------------------------------------------------------
// Static frontend
// ----------------------------------------------------------------------------
app.use(express.static(path.join(__dirname, 'public')));

app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

const PORT = process.env.PORT || 3000;
http.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT}`);
});
