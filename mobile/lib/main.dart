import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'asr_engine.dart';
import 'katha_data.dart';
import 'matching_engine.dart';
import 'theme.dart';
import 'widgets/debug_monitor.dart';
import 'widgets/katha_viewer.dart';

const List<String> _modelAssetFiles = [
  'encoder-epoch-12-avg-5.int8.onnx',
  'decoder-epoch-12-avg-5.int8.onnx',
  'joiner-epoch-12-avg-5.int8.onnx',
  'tokens.txt',
  'bpe_vocab.txt',
];
const String _vadAssetFile = 'silero_vad.onnx';

void main() {
  runApp(const MillionChantingApp());
}

class MillionChantingApp extends StatelessWidget {
  const MillionChantingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'พระคาถาเงินล้าน',
      theme: appTheme,
      home: const ChantingScreen(),
    );
  }
}

class ChantingScreen extends StatefulWidget {
  const ChantingScreen({super.key});
  @override
  State<ChantingScreen> createState() => _ChantingScreenState();
}

class _ChantingScreenState extends State<ChantingScreen> {
  final _matching = MatchingEngine();
  AsrEngine? _asr;

  bool _isRecording = false;
  bool _modelLoading = true;
  String _modelLoadError = '';
  bool _loopJustCompleted = false;

  String _currentTranscriptHtml = '-';
  final List<String> _history = [];
  String _captureStatus = 'not started';
  int _chunkCount = 0;
  String _lastDecodeTiming = '';

  Timer? _idleTimer;
  static const _idleTimeout = Duration(minutes: 5);

  StreamSubscription? _partialSub, _finalSub, _captureSub, _decodeSub;

  @override
  void initState() {
    super.initState();
    _matching.onChange = () => setState(() {});
    _initModel();
  }

  Future<String> _extractAssetsToDir(List<String> files, String assetSubdir, Directory targetDir) async {
    for (final name in files) {
      final targetFile = File('${targetDir.path}/$name');
      if (await targetFile.exists()) continue; // already extracted, matches fetch-model.js's skip-if-present pattern
      final assetPath = assetSubdir.isEmpty ? 'assets/$name' : 'assets/$assetSubdir/$name';
      final data = await rootBundle.load(assetPath);
      await targetFile.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return targetDir.path;
  }

  Future<void> _initModel() async {
    try {
      final appDir = await getApplicationSupportDirectory();
      final modelDir = Directory('${appDir.path}/model');
      await modelDir.create(recursive: true);

      await _extractAssetsToDir(_modelAssetFiles, 'model', modelDir);
      await _extractAssetsToDir([_vadAssetFile], '', appDir);

      final hotwordsFile = File('${appDir.path}/katha_hotwords.txt');
      await hotwordsFile.writeAsString(buildHotwordsFileContent(), flush: true);

      final asr = AsrEngine(
        modelDir: modelDir.path,
        vadModelPath: '${appDir.path}/$_vadAssetFile',
        hotwordsFilePath: hotwordsFile.path,
      );
      await asr.loadModel();

      _partialSub = asr.onTranscriptPartial.listen((text) => _onTranscript(text, isFinal: false));
      _finalSub = asr.onTranscript.listen((text) => _onTranscript(text, isFinal: true));
      _captureSub = asr.onCaptureStatus.listen((status) => setState(() {
            _captureStatus = status;
            _chunkCount = asr.chunkCount;
          }));
      _decodeSub = asr.onDecodeTiming.listen((timing) => setState(() => _lastDecodeTiming = timing));

      setState(() {
        _asr = asr;
        _modelLoading = false;
      });
    } catch (e, st) {
      setState(() {
        _modelLoading = false;
        _modelLoadError = '$e\n$st';
      });
    }
  }

  void _onTranscript(String text, {required bool isFinal}) {
    if (!_isRecording) return;
    if (text.trim().isNotEmpty) _resetIdleTimer();

    final loopCompleted = _matching.advance(text, isFinal);

    var displayHtml = text;
    for (final kw in _matching.sessionMatchedKeywords) {
      displayHtml = displayHtml.replaceAll(kw, '§$kw§');
    }

    setState(() {
      _currentTranscriptHtml = displayHtml.isNotEmpty ? displayHtml : '-';
      if (loopCompleted) _loopJustCompleted = true;
    });

    if (loopCompleted) {
      // One frame later, drop the flag so KathaViewer's didUpdateWidget only
      // triggers the wrap animation once per completion, mirroring the web
      // version's isLoopCompletion being a one-shot per updateUI() call.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _loopJustCompleted = false);
      });
    }

    if (isFinal) {
      if (_currentTranscriptHtml != '-') {
        setState(() {
          _history.insert(0, _currentTranscriptHtml);
          _currentTranscriptHtml = '-';
        });
      }
    }
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    if (_isRecording) {
      _idleTimer = Timer(_idleTimeout, () {
        _showMessage('⏳ ระบบหยุดการฟังอัตโนมัติ เนื่องจากตรวจไม่พบเสียงสวดมนต์เป็นเวลานาน');
        _stopChanting();
      });
    }
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _startChanting() async {
    final asr = _asr;
    if (asr == null) return;

    setState(() {
      _history.clear();
      _currentTranscriptHtml = '-';
      _matching.debugLog.clear();
    });

    try {
      await asr.start();
      setState(() => _isRecording = true);
      _resetIdleTimer();
    } catch (e) {
      _showMessage('ไม่สามารถเข้าถึงไมโครโฟนได้ หรือไมค์อาจถูกใช้งานอยู่: $e');
    }
  }

  Future<void> _stopChanting() async {
    if (!_isRecording) return;
    _idleTimer?.cancel();
    setState(() => _isRecording = false);
    await _asr?.stop();
  }

  bool _resetConfirming = false;
  Timer? _resetConfirmTimer;

  void _onResetTap() {
    if (!_resetConfirming) {
      setState(() => _resetConfirming = true);
      _resetConfirmTimer?.cancel();
      _resetConfirmTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _resetConfirming = false);
      });
    } else {
      _resetConfirmTimer?.cancel();
      setState(() {
        _matching.reset();
        _history.clear();
        _currentTranscriptHtml = '-';
        _resetConfirming = false;
      });
    }
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _resetConfirmTimer?.cancel();
    _partialSub?.cancel();
    _finalSub?.cancel();
    _captureSub?.cancel();
    _decodeSub?.cancel();
    _asr?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_modelLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: AppColors.gold)));
    }
    if (_modelLoadError.isNotEmpty) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('โหลดโมเดลไม่สำเร็จ:\n$_modelLoadError', style: const TextStyle(color: AppColors.danger)),
          ),
        ),
      );
    }

    final progress = _matching.currentLine / kathaLines.length;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 600),
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 40),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.gold.withValues(alpha: 0.1)),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 50, offset: const Offset(0, 20))],
              ),
              child: Column(
                children: [
                  const Text('พระคาถาเงินล้าน', style: TextStyle(color: AppColors.gold, fontSize: 36, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  const Text('⚠ ระบบยังไม่รองรับการสวดเร็วเร่งรีบ', style: TextStyle(color: Color(0xFF666666), fontStyle: FontStyle.italic)),
                  const SizedBox(height: 30),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      const Text('สวดแล้ว', style: TextStyle(color: AppColors.textMuted, letterSpacing: 2)),
                      const SizedBox(width: 10),
                      Text('${_matching.loopCount}', style: const TextStyle(color: AppColors.goldLight, fontSize: 80, fontWeight: FontWeight.w300)),
                      const SizedBox(width: 10),
                      const Text('จบ', style: TextStyle(color: AppColors.textMuted, letterSpacing: 2)),
                    ],
                  ),
                  const SizedBox(height: 30),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value: progress.clamp(0, 1),
                      minHeight: 6,
                      backgroundColor: Colors.white.withValues(alpha: 0.05),
                      valueColor: const AlwaysStoppedAnimation(AppColors.gold),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: _isRecording ? _stopChanting : _startChanting,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isRecording ? AppColors.danger.withValues(alpha: 0.15) : AppColors.gold.withValues(alpha: 0.1),
                          foregroundColor: _isRecording ? AppColors.danger : AppColors.gold,
                          side: BorderSide(color: (_isRecording ? AppColors.danger : AppColors.gold).withValues(alpha: 0.5)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                        ),
                        child: Text(_isRecording ? '🛑 หยุดสวด' : '🎤 เริ่มสวดมนต์ 🗣'),
                      ),
                      const SizedBox(width: 15),
                      OutlinedButton(
                        onPressed: _onResetTap,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _resetConfirming ? AppColors.danger : AppColors.textMuted,
                          side: BorderSide(color: _resetConfirming ? AppColors.danger.withValues(alpha: 0.5) : const Color(0xFF333333)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                        ),
                        child: Text(_resetConfirming ? '⚠️ ยืนยันรีเซ็ต?' : '⟳ รีเซ็ต'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),
                  Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      title: const Text('แสดงความคืบหน้า (อย่างหยาบ)', style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                      children: [
                        KathaViewer(currentLine: _matching.currentLine, loopJustCompleted: _loopJustCompleted),
                      ],
                    ),
                  ),
                  DebugMonitor(
                    activeText: _matching.activeTextForDebug,
                    cursor: _matching.sessionMatchCursor,
                    captureStatus: _captureStatus,
                    chunkCount: _chunkCount,
                    lastDecodeTiming: _lastDecodeTiming,
                    logEntries: _matching.debugLog,
                  ),
                  const SizedBox(height: 25),
                  const Align(alignment: Alignment.centerLeft, child: Text('เสียงที่จับได้:', style: TextStyle(color: AppColors.textMuted))),
                  const SizedBox(height: 10),
                  if (_history.isNotEmpty)
                    Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 120),
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(8)),
                      child: ListView(
                        shrinkWrap: true,
                        children: _history
                            .map((h) => Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: _highlightedText(h, italic: true, color: const Color(0xFF5A5A66)),
                                ))
                            .toList(),
                      ),
                    ),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 30),
                    padding: const EdgeInsets.only(left: 10),
                    decoration: const BoxDecoration(border: Border(left: BorderSide(color: AppColors.gold, width: 3))),
                    child: _highlightedText(_currentTranscriptHtml, color: const Color(0xFFCCCCCC)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Renders text with §keyword§ markers (set in _onTranscript) as
  // highlighted spans - the Dart equivalent of index.html's
  // trigger-highlight <span> injection.
  Widget _highlightedText(String text, {bool italic = false, Color color = const Color(0xFFCCCCCC)}) {
    final spans = <TextSpan>[];
    final parts = text.split('§');
    for (int i = 0; i < parts.length; i++) {
      final isHighlight = i.isOdd;
      spans.add(TextSpan(
        text: parts[i],
        style: isHighlight
            ? const TextStyle(
                color: Color(0xFF7FE8AC),
                fontWeight: FontWeight.bold,
                backgroundColor: Color(0x332ECC71),
              )
            : TextStyle(color: color, fontStyle: italic ? FontStyle.italic : FontStyle.normal),
      ));
    }
    return RichText(text: TextSpan(children: spans, style: const TextStyle(fontSize: 16)));
  }
}
