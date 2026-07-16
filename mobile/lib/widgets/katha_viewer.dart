import 'package:flutter/material.dart';
import '../katha_data.dart';
import '../theme.dart';

/// Ported from index.html's #kathaSlider CSS carousel: 3 panels (page1,
/// page2, an invisible page1-clone) that always slide forward (left),
/// including on loop wraparound - see HANDOFF.md "UI conventions to
/// preserve": never let a loop wrap flip backward. The clone panel is what
/// makes that possible - wrapping slides into the clone (visually identical
/// to page1's post-wrap state), then snaps back to the real page1 instantly
/// once off-screen, so the viewer only ever sees continuous forward motion.
class KathaViewer extends StatefulWidget {
  final int currentLine;
  final bool loopJustCompleted;

  const KathaViewer({super.key, required this.currentLine, required this.loopJustCompleted});

  @override
  State<KathaViewer> createState() => KathaViewerState();
}

class KathaViewerState extends State<KathaViewer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  int _page = 0; // 0 = page1, 1 = page2, 2 = page1Clone (transient, wrap only)
  static const List<double> _pagePercents = [0, -1 / 3, -2 / 3];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      value: 0,
    );
  }

  @override
  void didUpdateWidget(covariant KathaViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loopJustCompleted && !oldWidget.loopJustCompleted) {
      _wrapToStart();
    } else if (!widget.loopJustCompleted) {
      final targetPage = widget.currentLine >= 6 ? 1 : 0;
      if (targetPage != _page) _setPage(targetPage);
    }
  }

  void _setPage(int page, {bool instant = false}) {
    _page = page;
    if (instant) {
      _controller.value = -_pagePercents[page];
    } else {
      _controller.animateTo(-_pagePercents[page], curve: Curves.easeOutCubic);
    }
  }

  Future<void> _wrapToStart() async {
    _setPage(2);
    await Future.delayed(const Duration(milliseconds: 650));
    if (!mounted) return;
    setState(() => _setPage(0, instant: true));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return LayoutBuilder(builder: (context, constraints) {
            final panelWidth = constraints.maxWidth;
            final offset = -_controller.value * panelWidth;
            return SizedBox(
              height: 260,
              child: Stack(
                children: [
                  Positioned(
                    left: offset,
                    width: panelWidth,
                    child: _KathaPage(lineRange: const [0, 1, 2, 3, 4, 5], currentLine: widget.currentLine),
                  ),
                  Positioned(
                    left: offset + panelWidth,
                    width: panelWidth,
                    child: _KathaPage(lineRange: const [6, 7, 8, 9, 10, 11], currentLine: widget.currentLine),
                  ),
                  Positioned(
                    left: offset + panelWidth * 2,
                    width: panelWidth,
                    // Clone always mirrors page1's state - only ever visible
                    // transiently mid-wrap, at which point currentLine is
                    // already back to 0 (post-wrap state) same as page1.
                    child: _KathaPage(lineRange: const [0, 1, 2, 3, 4, 5], currentLine: widget.currentLine),
                  ),
                ],
              ),
            );
          });
        },
      ),
    );
  }
}

class _KathaPage extends StatelessWidget {
  final List<int> lineRange;
  final int currentLine;

  const _KathaPage({required this.lineRange, required this.currentLine});

  @override
  Widget build(BuildContext context) {
    // Lines 6-9 (indices in lineRange when on page 2) are visually grouped
    // under one shared bracket + desc, matching index.html's group-wrapper
    // for kathaLines[6..9] sharing "คาถาพระปัจเจกพุทธเจ้า".
    final isPage2 = lineRange.first == 6;

    if (!isPage2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lineRange.map((i) => _lineRow(kathaLines[i], i)).toList(),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _lineRow(kathaLines[6], 6),
        _lineRow(kathaLines[7], 7),
        _lineRow(kathaLines[8], 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                children: [_lineText(kathaLines[9], 9)],
              ),
            ),
            _descBadge(kathaLines[9].desc),
          ],
        ),
      ],
    );
  }

  Widget _lineRow(KathaLine line, int index) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: _lineText(line, index)),
          const SizedBox(width: 10),
          _descBadge(line.desc),
        ],
      ),
    );
  }

  Widget _lineText(KathaLine line, int index) {
    final isCompleted = index < currentLine;
    final isActive = index == currentLine;

    final textWidget = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: isActive
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: const LinearGradient(colors: [AppColors.gold, Colors.white, AppColors.gold]),
            )
          : null,
      child: Container(
        padding: isActive ? const EdgeInsets.all(1.5) : EdgeInsets.zero,
        decoration: isActive
            ? BoxDecoration(borderRadius: BorderRadius.circular(6.5), color: AppColors.card)
            : null,
        child: Padding(
          padding: isActive ? const EdgeInsets.symmetric(horizontal: 10.5, vertical: 6.5) : EdgeInsets.zero,
          child: Text(
            line.text,
            style: TextStyle(
              fontSize: 15,
              color: isCompleted ? AppColors.gold.withValues(alpha: 0.7) : (isActive ? AppColors.textMain : const Color(0xFF333333)),
            ),
          ),
        ),
      ),
    );
    return textWidget;
  }

  Widget _descBadge(String desc) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 120),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.05),
        border: Border.all(color: AppColors.gold.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        desc,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 10, color: AppColors.gold, height: 1.3),
      ),
    );
  }
}
