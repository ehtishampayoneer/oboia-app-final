// lib/widgets/debug_overlay.dart
//
// Floating debug overlay. Drop this widget on top of any Stack and you
// get a small "bug" button in the bottom-left of the screen. Tap it to
// open a translucent panel showing the latest debug logs. Has a "Copy"
// button so you can paste logs into a chat or email without needing
// a Mac, Xcode, or any cable.

import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/debug_log_service.dart';

class DebugOverlay extends StatefulWidget {
  /// Filter substring — only show lines containing this text.
  /// Pass null to show everything.
  final String? filter;

  /// Where the floating button sits.
  final Alignment alignment;

  const DebugOverlay({
    super.key,
    this.filter,
    this.alignment = Alignment.bottomLeft,
  });

  @override
  State<DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends State<DebugOverlay> {
  bool _expanded = false;
  List<LogLine> _lines = const [];
  late final Stream<List<LogLine>> _stream;

  @override
  void initState() {
    super.initState();
    _lines = DebugLogService.instance.lines;
    _stream = DebugLogService.instance.stream;
  }

  List<LogLine> get _visible {
    final f = widget.filter;
    if (f == null || f.isEmpty) return _lines;
    return _lines.where((l) => l.message.contains(f)).toList();
  }

  Future<void> _copyAll() async {
    final visible = _visible;
    final text = visible.map((l) => l.toString()).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${visible.length} log lines copied'),
        duration: const Duration(seconds: 2),
        backgroundColor: Colors.black87,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).padding;

    return StreamBuilder<List<LogLine>>(
      stream: _stream,
      initialData: _lines,
      builder: (context, snap) {
        if (snap.hasData) _lines = snap.data!;
        final lines = _visible;

        return Stack(
          children: [
            if (_expanded)
              Positioned(
                left: 12,
                right: 12,
                bottom: padding.bottom + 70,
                top: padding.top + 80,
                child: _buildPanel(lines),
              ),
            Positioned(
              left: widget.alignment.x < 0 ? 12 : null,
              right: widget.alignment.x > 0 ? 12 : null,
              bottom: padding.bottom + 12,
              child: _buildBugButton(lines.length),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBugButton(int count) {
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: _expanded
              ? const Color(0xFFFFD369)
              : Colors.black.withValues(alpha: 0.7),
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFFFFD369),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(
              Icons.bug_report,
              size: 22,
              color: _expanded
                  ? Colors.black
                  : const Color(0xFFFFD369),
            ),
            if (count > 0 && !_expanded)
              Positioned(
                right: 2,
                top: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD369),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 16,
                    minHeight: 12,
                  ),
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel(List<LogLine> lines) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: const Color(0xFFFFD369).withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.bug_report,
                      color: Color(0xFFFFD369),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Debug · ${lines.length} lines',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    _ToolButton(
                      icon: Icons.copy,
                      tooltip: 'Copy',
                      onTap: _copyAll,
                    ),
                    _ToolButton(
                      icon: Icons.delete_outline,
                      tooltip: 'Clear',
                      onTap: () {
                        DebugLogService.instance.clear();
                      },
                    ),
                    _ToolButton(
                      icon: Icons.close,
                      tooltip: 'Close',
                      onTap: () => setState(() => _expanded = false),
                    ),
                  ],
                ),
              ),
              // Log lines
              Expanded(
                child: lines.isEmpty
                    ? const Center(
                        child: Text(
                          'No logs yet',
                          style: TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        itemCount: lines.length,
                        itemBuilder: (_, i) {
                          // Show newest at bottom
                          final line = lines[lines.length - 1 - i];
                          return _LogLineTile(line: line);
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 18, color: Colors.white70),
        onPressed: onTap,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(),
        splashRadius: 18,
      ),
    );
  }
}

class _LogLineTile extends StatelessWidget {
  final LogLine line;
  const _LogLineTile({required this.line});

  Color get _accent {
    final m = line.message.toLowerCase();
    if (m.contains('error') || m.contains('failed') || m.contains('exception')) {
      return Colors.redAccent;
    }
    if (m.contains('warn')) {
      return Colors.orangeAccent;
    }
    if (m.contains('[ar]')) {
      return const Color(0xFFFFD369);
    }
    return Colors.white70;
  }

  @override
  Widget build(BuildContext context) {
    final t = line.time;
    final timeStr =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            timeStr,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 10,
              fontFamily: 'Courier',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              line.message,
              style: TextStyle(
                color: _accent,
                fontSize: 11,
                fontFamily: 'Courier',
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
