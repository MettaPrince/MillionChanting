// Runs on the dedicated audio-rendering thread (AudioWorkletGlobalScope),
// isolated from the main thread's DOM/UI work. This is what replaced
// ScriptProcessorNode: its 'audioprocess' callback ran on the main thread,
// so on mobile CPUs it competed with UI rendering (katha viewer animation,
// transcript updates) for the same thread and caused capture lag under load
// - a laptop's CPU headroom hid the problem, mobile's didn't.
class PCMCaptureProcessor extends AudioWorkletProcessor {
    constructor(options) {
        super();
        this.targetSampleRate = options.processorOptions.targetSampleRate;
        this.chunkSize = options.processorOptions.chunkSize;
        this.buffer = new Float32Array(0);
    }

    // Box-filter downsample - same algorithm the main thread used to run,
    // just moved onto this thread. sherpa's model expects 16kHz mono; mic
    // input usually arrives at 44.1kHz/48kHz.
    downsampleTo16k(buffer, inputSampleRate) {
        if (inputSampleRate === this.targetSampleRate) return buffer;

        const ratio = inputSampleRate / this.targetSampleRate;
        const newLength = Math.round(buffer.length / ratio);
        const result = new Float32Array(newLength);

        let offsetResult = 0;
        let offsetBuffer = 0;
        while (offsetResult < newLength) {
            const nextOffsetBuffer = Math.round((offsetResult + 1) * ratio);
            let accum = 0;
            let count = 0;
            for (let i = offsetBuffer; i < nextOffsetBuffer && i < buffer.length; i++) {
                accum += buffer[i];
                count++;
            }
            result[offsetResult] = count > 0 ? accum / count : 0;
            offsetResult++;
            offsetBuffer = nextOffsetBuffer;
        }
        return result;
    }

    floatTo16BitPCM(float32Array) {
        const int16Array = new Int16Array(float32Array.length);
        for (let i = 0; i < float32Array.length; i++) {
            const s = Math.max(-1, Math.min(1, float32Array[i]));
            int16Array[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
        }
        return int16Array;
    }

    // Called every ~128-sample render quantum. Accumulate into chunkSize
    // (matches the previous ScriptProcessor buffer size) before doing the
    // resample/encode work, so downstream chunk cadence is unchanged.
    process(inputs) {
        const channelData = inputs[0] && inputs[0][0];
        if (!channelData || channelData.length === 0) return true;

        const merged = new Float32Array(this.buffer.length + channelData.length);
        merged.set(this.buffer, 0);
        merged.set(channelData, this.buffer.length);
        this.buffer = merged;

        if (this.buffer.length >= this.chunkSize) {
            const chunk = this.buffer.subarray(0, this.chunkSize);
            this.buffer = this.buffer.slice(this.chunkSize);

            // `sampleRate` is a read-only global in AudioWorkletGlobalScope -
            // the AudioContext's native rate.
            const resampled = this.downsampleTo16k(chunk, sampleRate);
            const pcm16 = this.floatTo16BitPCM(resampled);
            this.port.postMessage(pcm16.buffer, [pcm16.buffer]);
        }

        return true;
    }
}

registerProcessor('pcm-capture-processor', PCMCaptureProcessor);
