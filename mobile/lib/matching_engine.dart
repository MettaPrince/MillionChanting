import 'katha_data.dart';

class TriggerMatch {
  final String keyword;
  final int index;
  final int length;
  const TriggerMatch({required this.keyword, required this.index, required this.length});
}

class DebugLogEntry {
  final DateTime time;
  final String keyword;
  final int lineNumber; // 1-based, for display
  const DebugLogEntry({required this.time, required this.keyword, required this.lineNumber});
}

// Ported 1:1 from index.html's advanceMatching/findFirstMatch. This is the
// most-iterated piece of the whole project (see HANDOFF.md "Real-time
// matching design") - do not change the matching semantics without reading
// that section first. Fed by both a live-growing partial redecode and the
// final segment decode, through the SAME cursor, exactly like the web app.
class MatchingEngine {
  int currentLine = 0;
  int loopCount = 0;

  int _sessionMatchCursor = 0;
  final List<String> _sessionMatchedKeywords = [];
  static const int maxLookahead = 3;

  final List<DebugLogEntry> debugLog = [];

  // Set by the caller after each advance() call to react to UI-relevant
  // changes (line completed line change, loop wrap, display text change).
  void Function()? onChange;

  TriggerMatch? _findFirstMatch(String txt, List<String> words) {
    TriggerMatch? best;
    for (final kw in words) {
      final idx = txt.indexOf(kw);
      if (idx != -1) {
        if (best == null || idx < best.index) {
          best = TriggerMatch(keyword: kw, index: idx, length: kw.length);
        }
      }
    }
    return best;
  }

  String _cleanText = '';
  String get cleanText => _cleanText;
  int get sessionMatchCursor => _sessionMatchCursor;
  List<String> get sessionMatchedKeywords => List.unmodifiable(_sessionMatchedKeywords);

  /// isFinal mirrors the 'transcript' (true) vs 'transcript-partial' (false)
  /// distinction from server.js/index.html. Returns true if a loop
  /// completion happened during this call (caller may want to trigger the
  /// carousel's forward-wrap animation).
  bool advance(String text, bool isFinal) {
    _cleanText = (text).replaceAll(RegExp(r'\s+'), '');
    if (_cleanText.length < _sessionMatchCursor) {
      _sessionMatchCursor = _cleanText.length;
    }

    bool loopCompleted = false;

    while (_sessionMatchCursor < _cleanText.length) {
      final activeText = _cleanText.substring(_sessionMatchCursor);

      TriggerMatch? matchObj;
      int matchedCheckIndex = 0;
      int absoluteNewCurrentLine = currentLine;

      for (int offset = 0; offset <= maxLookahead; offset++) {
        final checkIndex = (currentLine + offset) % kathaLines.length;
        final line = kathaLines[checkIndex];
        final match = _findFirstMatch(activeText, line.triggerWords);
        if (match != null) {
          matchObj = match;
          matchedCheckIndex = checkIndex;
          absoluteNewCurrentLine = currentLine + offset + 1;
          break;
        }
      }

      if (matchObj == null) break;

      _sessionMatchedKeywords.add(matchObj.keyword);
      debugLog.insert(
        0,
        DebugLogEntry(time: DateTime.now(), keyword: matchObj.keyword, lineNumber: matchedCheckIndex + 1),
      );

      _sessionMatchCursor += matchObj.index + matchObj.length;

      final loopsAdded = (absoluteNewCurrentLine / kathaLines.length).floor();
      loopCount += loopsAdded;
      currentLine = absoluteNewCurrentLine % kathaLines.length;
      if (loopsAdded > 0) loopCompleted = true;
    }

    if (isFinal) {
      // Segment closed - reset session tracking so the next segment's
      // partial/final events start matching from a clean slate at cursor 0.
      _sessionMatchCursor = 0;
      _sessionMatchedKeywords.clear();
    }

    onChange?.call();
    return loopCompleted;
  }

  String get activeTextForDebug {
    final remainder = _cleanText.substring(_sessionMatchCursor.clamp(0, _cleanText.length));
    return remainder.isNotEmpty ? remainder : '[รอรับเสียง]';
  }

  void reset() {
    currentLine = 0;
    loopCount = 0;
    _sessionMatchCursor = 0;
    _sessionMatchedKeywords.clear();
    _cleanText = '';
    debugLog.clear();
  }
}
