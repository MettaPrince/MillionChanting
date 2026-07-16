import 'package:flutter/material.dart';
import '../matching_engine.dart';
import '../theme.dart';

/// Ported from index.html's "Debug Monitor" panel. The original's
/// "Connection" row (Socket.IO transport/ping) doesn't apply on-device -
/// there's no server round-trip anymore - so it's replaced with decode
/// timing (RTF), which is the on-device equivalent diagnostic.
class DebugMonitor extends StatelessWidget {
  final String activeText;
  final int cursor;
  final String captureStatus;
  final int chunkCount;
  final String lastDecodeTiming;
  final List<DebugLogEntry> logEntries;

  const DebugMonitor({
    super.key,
    required this.activeText,
    required this.cursor,
    required this.captureStatus,
    required this.chunkCount,
    required this.lastDecodeTiming,
    required this.logEntries,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: const Text('Debug Monitor (ตรวจสอบการทำงาน)', style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(15),
          color: Colors.black.withValues(alpha: 0.6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row('Active Text:', activeText, valueColor: const Color(0xFF888888)),
              _row('System State:', 'Cursor: $cursor | Lookahead: ${MatchingEngine.maxLookahead}'),
              _row('Capture:', captureStatus),
              _row('Decode:', lastDecodeTiming.isEmpty ? '-' : lastDecodeTiming),
              const SizedBox(height: 6),
              const Text('Trigger Logs:', style: TextStyle(color: Color(0xFF555555), fontSize: 12)),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 150),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.02)),
                ),
                child: logEntries.isEmpty
                    ? const SizedBox.shrink()
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: logEntries.length,
                        itemBuilder: (context, i) {
                          final e = logEntries[i];
                          final timeStr = '${e.time.hour.toString().padLeft(2, '0')}:'
                              '${e.time.minute.toString().padLeft(2, '0')}:'
                              '${e.time.second.toString().padLeft(2, '0')}';
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: RichText(
                              text: TextSpan(
                                style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Color(0xFFA0A0A0)),
                                children: [
                                  TextSpan(text: '[$timeStr] จับคำว่า '),
                                  TextSpan(
                                    text: e.keyword,
                                    style: const TextStyle(
                                      color: Color(0xFF7FE8AC),
                                      fontWeight: FontWeight.bold,
                                      backgroundColor: Color(0x332ECC71),
                                    ),
                                  ),
                                  const TextSpan(text: ' ➔ '),
                                  TextSpan(
                                    text: '[วรรค ${e.lineNumber}]',
                                    style: const TextStyle(color: Color(0xFF3498DB), fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(String label, String value, {Color valueColor = const Color(0xFF777777)}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          children: [
            TextSpan(text: '${label.padRight(12)} ', style: const TextStyle(color: Color(0xFF555555))),
            TextSpan(text: value, style: TextStyle(color: valueColor)),
          ],
        ),
      ),
    );
  }
}
