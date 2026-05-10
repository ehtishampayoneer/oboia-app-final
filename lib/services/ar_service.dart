// lib/services/ar_service.dart
//
// Dart-side bridge to native ARKit (iOS) / ARCore (Android) wallpaper renderer.
//
// v2.0 (May 2026) — bulletproof event bridge:
//   - Native events are buffered until the FIRST Dart listener attaches,
//     so the boot beacon never gets silently dropped.
//   - Every event is also captured into a circular ring buffer of the last
//     500 lines, accessible via ARService.instance.recentLogs.
//   - Logs are also appended to Documents/oboia-debug.log on every event,
//     surviving app restarts.
//   - DiagnosticLog.dump() returns the entire ring buffer as a String for
//     on-screen display.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/wallpaper_model.dart';

// ─────────────────────────────────────────────────────────────────────────
// DIAGNOSTIC LOG — global, never throws, always available
// ─────────────────────────────────────────────────────────────────────────

/// Global diagnostic log. Captures every meaningful event in the AR pipeline.
/// Three sinks for redundancy:
///  1) In-memory ring buffer (last 500 entries) — for on-screen viewer
///  2) debugPrint — flows to Flutter overlay + IDE + Codemagic build log
///  3) On-disk file: Documents/oboia-debug.log — survives app crashes
///
/// All sinks are best-effort. If file write fails, others continue.
class DiagnosticLog {
  DiagnosticLog._();
  static final DiagnosticLog instance = DiagnosticLog._();

  static const int _maxEntries = 500;
  final Queue<String> _ring = Queue<String>();
  File? _file;
  bool _fileInitInFlight = false;
  bool _fileInitFailed = false;

  /// Add a line to all sinks. Format: HH:mm:ss.SSS [tag] message.
  void log(String tag, String message) {
    final ts = _timestamp();
    final line = '$ts [$tag] $message';

    // Sink 1: ring buffer (for on-screen viewer)
    _ring.addLast(line);
    while (_ring.length > _maxEntries) {
      _ring.removeFirst();
    }

    // Sink 2: debugPrint (Flutter overlay, IDE)
    debugPrint(line);

    // Sink 3: file (best effort, async, never blocks)
    _appendToFile(line);
  }

  String _timestamp() {
    final now = DateTime.now();
    String pad(int n, [int w = 2]) => n.toString().padLeft(w, '0');
    return '${pad(now.hour)}:${pad(now.minute)}:${pad(now.second)}.${pad(now.millisecond, 3)}';
  }

  Future<void> _appendToFile(String line) async {
    if (_fileInitFailed) return;
    try {
      _file ??= await _initFile();
      if (_file == null) return;
      await _file!.writeAsString('$line\n', mode: FileMode.append, flush: false);
    } catch (_) {
      // Don't let file errors break logging. Subsequent calls will retry init.
    }
  }

  Future<File?> _initFile() async {
    if (_fileInitInFlight) return null;
    _fileInitInFlight = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/oboia-debug.log');
      // Truncate to keep it bounded across launches; comment this line if you want growing log.
      if (await f.exists() && (await f.length()) > 1024 * 1024) {
        await f.writeAsString(''); // reset if >1MB
      }
      _fileInitInFlight = false;
      return f;
    } catch (_) {
      _fileInitFailed = true;
      _fileInitInFlight = false;
      return null;
    }
  }

  /// Snapshot of the current ring buffer as a single string. Newest at the bottom.
  String dump() {
    return _ring.join('\n');
  }

  /// Clear the in-memory ring buffer (file is untouched).
  void clear() {
    _ring.clear();
  }

  /// Read entire on-disk log file as a string. Returns empty if no file yet.
  Future<String> readFileLog() async {
    try {
      final f = _file ?? await _initFile();
      if (f == null) return '';
      if (!await f.exists()) return '';
      return await f.readAsString();
    } catch (e) {
      return '(failed to read log file: $e)';
    }
  }
}

/// Convenience top-level logger.
void dlog(String tag, String message) {
  DiagnosticLog.instance.log(tag, message);
}

// ─────────────────────────────────────────────────────────────────────────
// AR EVENT MODEL
// ─────────────────────────────────────────────────────────────────────────

class AREvent {
  final String type;
  final Map<String, dynamic> data;

  const AREvent({required this.type, required this.data});

  factory AREvent.fromMap(Map<String, dynamic> map) {
    final raw = map['data'];
    final Map<String, dynamic> data = raw is Map
        ? raw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    return AREvent(
      type: (map['type'] ?? '').toString(),
      data: data,
    );
  }

  int? get wallIndex => data['wallIndex'] is int
      ? data['wallIndex'] as int
      : (data['wallIndex'] as num?)?.toInt();

  double? get width => (data['width'] as num?)?.toDouble();
  double? get height => (data['height'] as num?)?.toDouble();
  double? get sqm => (data['sqm'] as num?)?.toDouble();
  bool? get success => data['success'] as bool?;
  String? get errorCode => data['code'] as String?;
  String? get errorMessage => data['message'] as String?;

  int? get cutCount => data['cutCount'] is int
      ? data['cutCount'] as int
      : (data['cutCount'] as num?)?.toInt();

  String? get tool => data['tool'] as String?;
  bool? get locked => data['locked'] as bool?;
  int? get obstacleCount => data['count'] is int
      ? data['count'] as int
      : (data['count'] as num?)?.toInt();

  String? get reason => data['reason'] as String?;
  int? get cornerNumber => data['corner'] is int
      ? data['corner'] as int
      : (data['corner'] as num?)?.toInt();
  int? get totalCorners => data['total'] is int
      ? data['total'] as int
      : (data['total'] as num?)?.toInt();
}

class WallMeasurements {
  final int wallIndex;
  final double width;
  final double height;
  final double sqm;

  const WallMeasurements({
    required this.wallIndex,
    required this.width,
    required this.height,
    required this.sqm,
  });

  int rollsNeeded({required double rollWidth, required double rollLength}) {
    final perRoll = rollWidth * rollLength;
    if (perRoll <= 0) return 0;
    return (sqm / perRoll).ceil();
  }

  double totalPrice({
    required double rollWidth,
    required double rollLength,
    required double pricePerRoll,
  }) {
    return rollsNeeded(rollWidth: rollWidth, rollLength: rollLength) * pricePerRoll;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// ARSERVICE — bulletproof bridge with buffering
// ─────────────────────────────────────────────────────────────────────────

class ARService {
  ARService._();
  static final ARService instance = ARService._();

  static const _channel = MethodChannel('com.oboia/ar');
  static const _eventChannel = EventChannel('com.oboia/ar_events');

  /// Sync stream controller: events are delivered immediately to all listeners,
  /// but if no listener is attached yet, we buffer in [_pendingEvents].
  final StreamController<AREvent> _controller = StreamController<AREvent>.broadcast();

  /// Events that arrived from native before Dart attached its first listener.
  /// Drained as soon as a listener attaches.
  final List<AREvent> _pendingEvents = [];

  /// True once at least one listener has subscribed via [events] getter.
  bool _hasListener = false;

  StreamSubscription<dynamic>? _eventSub;
  bool _initialized = false;

  /// Stream of native events. The first listener triggers a drain of any
  /// events that arrived early.
  Stream<AREvent> get events {
    return Stream<AREvent>.multi((controller) {
      _hasListener = true;
      dlog('AR-DART', 'listener attached, draining ${_pendingEvents.length} pending events');

      // Drain any buffered events to this new listener
      final buffered = List<AREvent>.from(_pendingEvents);
      _pendingEvents.clear();
      for (final ev in buffered) {
        controller.add(ev);
      }

      // Subscribe controller to live stream
      final sub = _controller.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );

      controller.onCancel = () {
        sub.cancel();
      };
    });
  }

  void _emit(AREvent ev) {
    dlog('AR-DART', 'event recv type=${ev.type} data=${ev.data}');
    if (_hasListener) {
      _controller.add(ev);
    } else {
      _pendingEvents.add(ev);
      if (_pendingEvents.length > 200) {
        _pendingEvents.removeAt(0); // bound buffer
      }
    }
  }

  Future<void> initAR() async {
    dlog('AR-DART', 'initAR() called, _initialized=$_initialized');
    if (_initialized) {
      dlog('AR-DART', 'initAR() already initialized — ensuring listener still attached');
      if (_eventSub == null) {
        _attachEventChannel();
      }
      return;
    }
    _initialized = true;

    // CRITICAL: invoke initAR method FIRST. This forces the native side
    // to be ready. Then wait a brief moment for the platform view to
    // finish setting up its EventChannel stream handler. THEN attach
    // the Dart listener — this guarantees Swift's onListen fires.
    try {
      dlog('AR-DART', 'invoking initAR method on channel (before event channel attach)');
      await _channel.invokeMethod<void>('initAR');
      dlog('AR-DART', 'initAR method returned successfully');
    } on PlatformException catch (e) {
      dlog('AR-DART', 'initAR method FAILED: code=${e.code} msg=${e.message}');
      _emit(AREvent(
        type: 'error',
        data: {'code': e.code, 'message': e.message ?? ''},
      ));
      return;
    }

    // Wait one frame so that the UiKitView has been built and ARWallpaperView.init()
    // has run its setupChannels(), which calls eventChannel.setStreamHandler(self).
    // Without this delay, the Dart subscription happens before Swift registers
    // the stream handler, and the connection is silently lost.
    await Future.delayed(const Duration(milliseconds: 800));

    dlog('AR-DART', 'attaching event channel listener (after native ready)');
    _attachEventChannel();
  }

  void _attachEventChannel() {
    dlog('AR-DART', 'attaching to event channel com.oboia/ar_events');
    _eventSub = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final map = event.map((k, v) => MapEntry(k.toString(), v));
          _emit(AREvent.fromMap(map));
        } else {
          dlog('AR-DART', 'event channel got non-Map: ${event.runtimeType}');
        }
      },
      onError: (err) {
        dlog('AR-DART', 'event channel ERROR: $err');
        _emit(AREvent(
          type: 'error',
          data: {'message': err.toString(), 'code': 'stream_error'},
        ));
      },
      onDone: () {
        dlog('AR-DART', 'event channel closed (onDone)');
      },
    );
    dlog('AR-DART', 'event channel listener attached');
  }

  // ── Wallpaper Methods ───────────────────────────────────────────────────

  Future<void> placeWallpaper({
    required WallpaperModel wallpaper,
    required int wallIndex,
    required double pricePerRoll,
  }) async {
    dlog('AR-DART', 'placeWallpaper wallIndex=$wallIndex name="${wallpaper.name}"');
    dlog('AR-DART', '  albedoUrl="${wallpaper.pbr.albedoUrl}"');
    dlog('AR-DART', '  rollWidth=${wallpaper.rollWidth} rollLength=${wallpaper.rollLength}');
    try {
      await _channel.invokeMethod<void>('placeWallpaper', {
        'albedoUrl': wallpaper.pbr.albedoUrl,
        'normalUrl': wallpaper.pbr.normalUrl,
        'roughnessUrl': wallpaper.pbr.roughnessUrl,
        'aoUrl': wallpaper.pbr.aoUrl,
        'rollWidth': wallpaper.rollWidth,
        'rollLength': wallpaper.rollLength,
        'pricePerRoll': pricePerRoll,
        'wallIndex': wallIndex,
      });
      dlog('AR-DART', 'placeWallpaper method returned OK');
    } on PlatformException catch (e) {
      dlog('AR-DART', 'placeWallpaper FAILED: ${e.code} ${e.message}');
      rethrow;
    }
  }

  Future<void> switchWallpaper({
    required WallpaperModel wallpaper,
    required int wallIndex,
    required double pricePerRoll,
  }) async {
    dlog('AR-DART', 'switchWallpaper wallIndex=$wallIndex name="${wallpaper.name}"');
    try {
      await _channel.invokeMethod<void>('switchWallpaper', {
        'albedoUrl': wallpaper.pbr.albedoUrl,
        'normalUrl': wallpaper.pbr.normalUrl,
        'roughnessUrl': wallpaper.pbr.roughnessUrl,
        'aoUrl': wallpaper.pbr.aoUrl,
        'rollWidth': wallpaper.rollWidth,
        'rollLength': wallpaper.rollLength,
        'pricePerRoll': pricePerRoll,
        'wallIndex': wallIndex,
      });
      dlog('AR-DART', 'switchWallpaper method returned OK');
    } on PlatformException catch (e) {
      dlog('AR-DART', 'switchWallpaper FAILED: ${e.code} ${e.message}');
      rethrow;
    }
  }

  Future<void> selectWall(int wallIndex) async {
    dlog('AR-DART', 'selectWall wallIndex=$wallIndex');
    await _channel.invokeMethod<void>('selectWall', {'wallIndex': wallIndex});
  }

  Future<void> clearWall(int wallIndex) async {
    dlog('AR-DART', 'clearWall wallIndex=$wallIndex');
    await _channel.invokeMethod<void>('clearWall', {'wallIndex': wallIndex});
  }

  Future<WallMeasurements?> getWallMeasurements(int wallIndex) async {
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'getWallMeasurements',
      {'wallIndex': wallIndex},
    );
    if (res == null) return null;
    return WallMeasurements(
      wallIndex: wallIndex,
      width: (res['width'] as num).toDouble(),
      height: (res['height'] as num).toDouble(),
      sqm: (res['sqm'] as num).toDouble(),
    );
  }

  Future<void> lockWall({required int wallIndex, required bool locked}) async {
    dlog('AR-DART', 'lockWall wallIndex=$wallIndex locked=$locked');
    await _channel.invokeMethod<void>('lockWall', {
      'wallIndex': wallIndex,
      'locked': locked,
    });
  }

  Future<void> disposeAR() async {
    dlog('AR-DART', 'disposeAR called');
    try {
      await _channel.invokeMethod<void>('disposeAR');
    } catch (_) {}
    await _eventSub?.cancel();
    _eventSub = null;
    _initialized = false;
    dlog('AR-DART', 'disposeAR complete');
  }

  // ── Phase 1: RoomPlan Scanning ─────────────────────────────────────────

  /// Start a RoomPlan-driven scan. Native side will stream `scanUpdate`
  /// events containing arrays of detected walls/doors/windows/objects.
  Future<void> startScan() async {
    dlog('AR-DART', 'startScan invoked');
    await _channel.invokeMethod<void>('startScan');
    dlog('AR-DART', 'startScan method returned');
  }

  /// Stop the current scan. Native fires `scanComplete` when post-processing
  /// finishes — this method does NOT wait for that event.
  Future<void> stopScan() async {
    dlog('AR-DART', 'stopScan invoked');
    try {
      await _channel.invokeMethod<void>('stopScan');
    } catch (_) {
      // ignore — stopping a non-running scan is fine
    }
  }

  /// Toggle whether a surface (wall/door/window) is excluded from wallpaper
  /// application. The next scanUpdate event will reflect the new state.
  Future<void> toggleSurfaceExclusion(String id) async {
    dlog('AR-DART', 'toggleSurfaceExclusion id=$id');
    await _channel.invokeMethod<void>('toggleSurfaceExclusion', {'id': id});
  }

  /// Toggle exclusion on a furniture object.
  Future<void> toggleObjectExclusion(String id) async {
    dlog('AR-DART', 'toggleObjectExclusion id=$id');
    await _channel.invokeMethod<void>('toggleObjectExclusion', {'id': id});
  }

  /// Switch native AR mode. Valid values: 'scanning', 'preview', 'legacy'.
  /// - scanning: ARKit auto-plane detection ignored; RoomPlan active.
  /// - preview:  scan complete; user taps walls to apply wallpaper.
  /// - legacy:   old behavior (auto-apply on plane detection). For testing.
  Future<void> setARMode(String mode) async {
    dlog('AR-DART', 'setARMode -> $mode');
    await _channel.invokeMethod<void>('setARMode', {'mode': mode});
  }

  // ── Manual Mode Methods ────────────────────────────────────────────────

  Future<void> enterManualMode() async {
    dlog('AR-DART', 'enterManualMode invoked');
    await _channel.invokeMethod<void>('enterManualMode');
    dlog('AR-DART', 'enterManualMode method returned');
  }

  Future<void> exitManualMode() async {
    dlog('AR-DART', 'exitManualMode invoked');
    await _channel.invokeMethod<void>('exitManualMode');
  }

  Future<void> resetManual() async {
    dlog('AR-DART', 'resetManual invoked');
    await _channel.invokeMethod<void>('resetManual');
  }

  // ── Cut Mode Methods ────────────────────────────────────────────────────

  Future<void> enterCutMode(int wallIndex) async {
    await _channel.invokeMethod<void>('enterCutMode', {'wallIndex': wallIndex});
  }

  Future<void> exitCutMode() async {
    await _channel.invokeMethod<void>('exitCutMode');
  }

  Future<void> smartCut({
    required double screenX,
    required double screenY,
    required int wallIndex,
  }) async {
    await _channel.invokeMethod<void>('smartCut', {
      'screenX': screenX,
      'screenY': screenY,
      'wallIndex': wallIndex,
    });
  }

  Future<void> rectangleCut({
    required double screenMinX,
    required double screenMinY,
    required double screenMaxX,
    required double screenMaxY,
    required int wallIndex,
  }) async {
    await _channel.invokeMethod<void>('rectangleCut', {
      'screenMinX': screenMinX,
      'screenMinY': screenMinY,
      'screenMaxX': screenMaxX,
      'screenMaxY': screenMaxY,
      'wallIndex': wallIndex,
    });
  }

  Future<void> freehandCut({
    required List<Map<String, double>> screenPoints,
    required int wallIndex,
  }) async {
    await _channel.invokeMethod<void>('freehandCut', {
      'screenPoints': screenPoints,
      'wallIndex': wallIndex,
    });
  }

  Future<void> circleCut({
    required double screenCenterX,
    required double screenCenterY,
    required double screenRadius,
    required int wallIndex,
  }) async {
    await _channel.invokeMethod<void>('circleCut', {
      'screenCenterX': screenCenterX,
      'screenCenterY': screenCenterY,
      'screenRadius': screenRadius,
      'wallIndex': wallIndex,
    });
  }

  Future<void> undoCut(int wallIndex) async {
    await _channel.invokeMethod<void>('undoCut', {'wallIndex': wallIndex});
  }

  Future<void> clearAllCuts(int wallIndex) async {
    await _channel.invokeMethod<void>('clearAllCuts', {'wallIndex': wallIndex});
  }
}
