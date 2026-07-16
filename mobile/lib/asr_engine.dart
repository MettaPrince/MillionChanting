import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'katha_data.dart';

/// Mirrors server.js's per-connection VAD + decode pipeline, but running
/// fully on-device: mic audio never leaves the phone. Same VAD settings,
/// same partial/final decode split, same hallucination stripping - see
/// HANDOFF.md "Known ASR-quirk mitigations" and "Real-time matching design"
/// for why these specific values/behaviors were chosen.
class AsrEngine {
  final String modelDir;
  final String vadModelPath;
  final String hotwordsFilePath;

  sherpa_onnx.OfflineRecognizer? _recognizer;
  sherpa_onnx.VoiceActivityDetector? _vad;
  final AudioRecorder _audioRecorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  Timer? _partialTimer;

  static const int sampleRate = 16000;
  static const int vadWindowSize = 512;
  static const int partialDecodeIntervalMs = 400;
  // 0.3s * 16000Hz - a literal since const expressions can't call .round().
  static const int partialDecodeMinSamples = 4800;
  static const List<String> hallucinationPhrases = ['เพลง'];

  Float32List _pending = Float32List(0);
  Float32List _speechBuffer = Float32List(0);
  bool _wasDetected = false;

  final _transcriptPartialController = StreamController<String>.broadcast();
  final _transcriptController = StreamController<String>.broadcast();
  final _captureStatusController = StreamController<String>.broadcast();
  final _decodeTimingController = StreamController<String>.broadcast();

  Stream<String> get onTranscriptPartial => _transcriptPartialController.stream;
  Stream<String> get onTranscript => _transcriptController.stream;
  Stream<String> get onCaptureStatus => _captureStatusController.stream;
  Stream<String> get onDecodeTiming => _decodeTimingController.stream;

  int chunkCount = 0;

  AsrEngine({required this.modelDir, required this.vadModelPath, required this.hotwordsFilePath});

  Future<void> loadModel() async {
    sherpa_onnx.initBindings();

    final config = sherpa_onnx.OfflineRecognizerConfig(
      model: sherpa_onnx.OfflineModelConfig(
        transducer: sherpa_onnx.OfflineTransducerModelConfig(
          encoder: '$modelDir/encoder-epoch-12-avg-5.int8.onnx',
          decoder: '$modelDir/decoder-epoch-12-avg-5.int8.onnx',
          joiner: '$modelDir/joiner-epoch-12-avg-5.int8.onnx',
        ),
        tokens: '$modelDir/tokens.txt',
        modelingUnit: 'bpe',
        bpeVocab: '$modelDir/bpe_vocab.txt',
        numThreads: 1,
        provider: 'cpu',
        debug: false,
      ),
      decodingMethod: 'modified_beam_search',
      maxActivePaths: 4,
      hotwordsFile: hotwordsFilePath,
      hotwordsScore: confirmedTriggerWordScore,
    );
    _recognizer = sherpa_onnx.OfflineRecognizer(config);
  }

  sherpa_onnx.VoiceActivityDetector _createVad() {
    final config = sherpa_onnx.VadModelConfig(
      sileroVad: sherpa_onnx.SileroVadModelConfig(
        model: vadModelPath,
        threshold: 0.6,
        minSilenceDuration: 0.35,
        minSpeechDuration: 0.35,
        maxSpeechDuration: 6,
        windowSize: vadWindowSize,
      ),
      sampleRate: sampleRate,
      numThreads: 1,
      provider: 'cpu',
      debug: false,
    );
    return sherpa_onnx.VoiceActivityDetector(config: config, bufferSizeInSeconds: 30);
  }

  String _stripHallucinations(String text) {
    var cleaned = text;
    for (final phrase in hallucinationPhrases) {
      cleaned = cleaned.replaceAll(phrase, '');
    }
    return cleaned;
  }

  /// Runs on the main isolate for this first testable build - a known,
  /// flagged tradeoff. recognizer.decode() is a synchronous native call, so
  /// a long decode (multi-second segments can take over a second - see
  /// HANDOFF.md's Render RTF logs) can cause a brief UI jank. Moving this to
  /// a background isolate is the natural next optimization once basic
  /// on-device behavior is validated on a real phone.
  String _decodeSegment(Float32List samples) {
    final recognizer = _recognizer!;
    final stream = recognizer.createStream();
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate);

    final audioSeconds = samples.length / sampleRate;
    final sw = Stopwatch()..start();
    recognizer.decode(stream);
    final decodeMs = sw.elapsedMilliseconds;
    final rtf = audioSeconds > 0 ? (decodeMs / 1000 / audioSeconds) : 0;
    _decodeTimingController.add(
      '${audioSeconds.toStringAsFixed(2)}s audio in ${decodeMs}ms (RTF ${rtf.toStringAsFixed(2)}x)',
    );

    final text = recognizer.getResult(stream).text;
    stream.free();
    return _stripHallucinations(text);
  }

  Float32List _pcm16BytesToFloat32(Uint8List bytes) {
    final byteData = ByteData.sublistView(bytes);
    final n = bytes.length ~/ 2;
    final out = Float32List(n);
    for (int i = 0; i < n; i++) {
      out[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  Future<void> start() async {
    if (_recognizer == null) {
      throw StateError('Model not loaded - call loadModel() first');
    }

    _vad?.free();
    _vad = _createVad();
    _pending = Float32List(0);
    _speechBuffer = Float32List(0);
    _wasDetected = false;
    chunkCount = 0;

    _captureStatusController.add('started, waiting for audio...');

    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) {
      _captureStatusController.add('ERROR: microphone permission denied');
      throw StateError('Microphone permission denied');
    }

    final micStream = await _audioRecorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        echoCancel: false,
        noiseSuppress: false,
        autoGain: false,
      ),
    );

    _micSub = micStream.listen(_onAudioChunk, onError: (e) {
      _captureStatusController.add('ERROR: $e');
    });

    _partialTimer?.cancel();
    _partialTimer = Timer.periodic(const Duration(milliseconds: partialDecodeIntervalMs), (_) {
      if (_speechBuffer.length < partialDecodeMinSamples) return;
      final text = _decodeSegment(_speechBuffer);
      if (text.trim().isNotEmpty) _transcriptPartialController.add(text);
    });
  }

  void _onAudioChunk(Uint8List bytes) {
    final vad = _vad;
    if (vad == null) return;

    final floatSamples = _pcm16BytesToFloat32(bytes);

    final combined = Float32List(_pending.length + floatSamples.length);
    combined.setAll(0, _pending);
    combined.setAll(_pending.length, floatSamples);

    int offset = 0;
    while (offset + vadWindowSize <= combined.length) {
      vad.acceptWaveform(combined.sublist(offset, offset + vadWindowSize));
      offset += vadWindowSize;
    }
    _pending = combined.sublist(offset);

    final nowDetected = vad.isDetected();
    if (nowDetected && !_wasDetected) {
      _speechBuffer = Float32List(0);
    }
    if (nowDetected) {
      final merged = Float32List(_speechBuffer.length + floatSamples.length);
      merged.setAll(0, _speechBuffer);
      merged.setAll(_speechBuffer.length, floatSamples);
      _speechBuffer = merged;
    }
    _wasDetected = nowDetected;

    while (!vad.isEmpty()) {
      final segment = vad.front();
      vad.pop();
      _speechBuffer = Float32List(0);
      _wasDetected = false;
      if (segment.samples.isNotEmpty) {
        final text = _decodeSegment(segment.samples);
        if (text.trim().isNotEmpty) _transcriptController.add(text);
      }
    }

    chunkCount++;
    _captureStatusController.add('active');
  }

  Future<void> stop() async {
    _partialTimer?.cancel();
    _partialTimer = null;
    await _micSub?.cancel();
    _micSub = null;
    await _audioRecorder.stop();

    // Flush anything still buffered as a final segment, matching server.js's
    // 'stop-audio' handler.
    final vad = _vad;
    if (vad != null) {
      while (!vad.isEmpty()) {
        final segment = vad.front();
        vad.pop();
        if (segment.samples.isNotEmpty) {
          final text = _decodeSegment(segment.samples);
          if (text.trim().isNotEmpty) _transcriptController.add(text);
        }
      }
      vad.free();
      _vad = null;
    }
    _pending = Float32List(0);
    _speechBuffer = Float32List(0);
    _wasDetected = false;
    _captureStatusController.add('stopped');
  }

  void dispose() {
    _partialTimer?.cancel();
    _micSub?.cancel();
    _audioRecorder.dispose();
    _vad?.free();
    _recognizer?.free();
    _transcriptPartialController.close();
    _transcriptController.close();
    _captureStatusController.close();
    _decodeTimingController.close();
  }
}
