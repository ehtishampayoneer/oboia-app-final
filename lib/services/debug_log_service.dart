// lib/services/debug_log_service.dart
//
// Captures debugPrint() output into a ring buffer that can be displayed
// in an on-screen overlay. Lets us see logs on a real iPhone without
// needing Xcode or a Mac.
//
// Usage:
//   1. In main.dart, call DebugLogService.instance.attach() before runApp
//   2. Anywhere, call debugPrint('...') as normal
//   3. Anywhere, listen to DebugLogService.instance.stream for live updates
//   4. Show the DebugOverlay widget on any screen

import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';

class LogLine {
  final DateTime time;
  final String message;
  const LogLine(this.time, this.message);

  @override
  String toString() {
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final ss = time.second.toString().padLeft(2, '0');
    final ms = time.millisecond.toString().padLeft(3, '0');
    return '[$hh:$mm:$ss.$ms] $message';
  }
}

class DebugLogService {
  DebugLogService._();
  static final DebugLogService instance = DebugLogService._();

  static const int _maxLines = 200;
  final Queue<LogLine> _buffer = Queue<LogLine>();
  final StreamController<List<LogLine>> _controller =
      StreamController<List<LogLine>>.broadcast();

  bool _attached = false;
  DebugPrintCallback? _originalPrint;

  /// Stream of the full ring buffer — fires every time a new line is added.
  Stream<List<LogLine>> get stream => _controller.stream;

  /// Snapshot of current lines.
  List<LogLine> get lines => List.unmodifiable(_buffer);

  /// All lines as a single string, ready to share.
  String asText() => _buffer.map((l) => l.toString()).join('\n');

  /// Replace Flutter's debugPrint so we capture every log call.
  /// Call once at app startup, before runApp().
  void attach() {
    if (_attached) return;
    _attached = true;
    _originalPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      // Forward to the original so console output still works in dev.
      _originalPrint?.call(message, wrapWidth: wrapWidth);
      if (message == null) return;
      _add(message);
    };
  }

  /// Manually add a line (useful for catch blocks).
  void log(String message) {
    _add(message);
  }

  void _add(String message) {
    final line = LogLine(DateTime.now(), message);
    _buffer.addLast(line);
    while (_buffer.length > _maxLines) {
      _buffer.removeFirst();
    }
    if (!_controller.isClosed) {
      _controller.add(List.unmodifiable(_buffer));
    }
  }

  void clear() {
    _buffer.clear();
    if (!_controller.isClosed) {
      _controller.add(const []);
    }
  }
}
