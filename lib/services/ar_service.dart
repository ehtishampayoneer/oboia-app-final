// lib/services/ar_service.dart
//
// Dart-side bridge to the native ARKit (iOS) and ARCore+Filament (Android)
// wallpaper renderer. Uses a MethodChannel for commands and an EventChannel
// for wall-detection / measurement / selection events.

import 'dart:async';
import 'package:flutter/services.dart';

import '../models/wallpaper_model.dart';

/// Event emitted by the native AR layer.
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

  // Convenience accessors for the common event payloads --------------------

  int? get wallIndex => data['wallIndex'] is int
      ? data['wallIndex'] as int
      : (data['wallIndex'] as num?)?.toInt();

  double? get width => (data['width'] as num?)?.toDouble();
  double? get height => (data['height'] as num?)?.toDouble();
  double? get sqm => (data['sqm'] as num?)?.toDouble();
  bool? get success => data['success'] as bool?;
  String? get errorCode => data['code'] as String?;
  String? get errorMessage => data['message'] as String?;

  // Cut mode event accessors -----------------------------------------------

  int? get cutCount => data['cutCount'] is int
      ? data['cutCount'] as int
      : (data['cutCount'] as num?)?.toInt();

  String? get tool => data['tool'] as String?;

  // CHANGED: Lock event accessor ------------------------------------------
  bool? get locked => data['locked'] as bool?;

  // CHANGED: Obstacle hint accessor ---------------------------------------
  int? get obstacleCount => data['count'] is int
      ? data['count'] as int
      : (data['count'] as num?)?.toInt();
}

/// Wall measurements computed from an AR plane extent.
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

  /// rollsNeeded = ceil(sqm / (rollWidth × rollLength)).
  int rollsNeeded({
    required double rollWidth,
    required double rollLength,
  }) {
    final perRoll = rollWidth * rollLength;
    if (perRoll <= 0) return 0;
    return (sqm / perRoll).ceil();
  }

  double totalPrice({
    required double rollWidth,
    required double rollLength,
    required double pricePerRoll,
  }) {
    return rollsNeeded(
          rollWidth: rollWidth,
          rollLength: rollLength,
        ) *
        pricePerRoll;
  }
}

/// Singleton bridge to the native AR renderer.
class ARService {
  ARService._();
  static final ARService instance = ARService._();

  static const _channel = MethodChannel('com.oboia/ar');
  static const _eventChannel = EventChannel('com.oboia/ar_events');

  final StreamController<AREvent> _controller =
      StreamController<AREvent>.broadcast();
  StreamSubscription<dynamic>? _eventSub;
  bool _initialized = false;

  /// Stream of native events (wallDetected, wallUpdated, wallSelected,
  /// wallpaperPlaced, cutUpdate, cutModeDone, cutToolChanged,
  /// wallLockChanged, obstacleHint, sessionInterrupted, sessionResumed,
  /// error, …).
  Stream<AREvent> get events => _controller.stream;

  /// Should be called once when the AR screen opens.
  Future<void> initAR() async {
    if (_initialized) return;
    _initialized = true;

    _eventSub = _eventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final map = event.map(
            (k, v) => MapEntry(k.toString(), v),
          );
          _controller.add(AREvent.fromMap(map));
        }
      },
      onError: (err) {
        _controller.add(AREvent(
          type: 'error',
          data: {
            'message': err.toString(),
            'code': 'stream_error',
          },
        ));
      },
    );

    try {
      await _channel.invokeMethod<void>('initAR');
    } on PlatformException catch (e) {
      _controller.add(AREvent(
        type: 'error',
        data: {
          'code': e.code,
          'message': e.message ?? '',
        },
      ));
    }
  }

  // ── Wallpaper Methods ───────────────────────────────────────────────────

  Future<void> placeWallpaper({
    required WallpaperModel wallpaper,
    required int wallIndex,
    required double pricePerRoll,
  }) async {
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
  }

  Future<void> switchWallpaper({
    required WallpaperModel wallpaper,
    required int wallIndex,
    required double pricePerRoll,
  }) async {
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
  }

  Future<void> selectWall(int wallIndex) async {
    await _channel.invokeMethod<void>(
      'selectWall',
      {'wallIndex': wallIndex},
    );
  }

  Future<void> clearWall(int wallIndex) async {
    await _channel.invokeMethod<void>(
      'clearWall',
      {'wallIndex': wallIndex},
    );
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

  /// CHANGED: Lock or unlock a wall.
  ///
  /// When locked, the native AR engine stops resizing the wall as ARKit
  /// refines the plane estimate. This lets the user walk around the room
  /// without the wallpaper subtly shifting. Unlocking resumes tracking.
  Future<void> lockWall({
    required int wallIndex,
    required bool locked,
  }) async {
    await _channel.invokeMethod<void>('lockWall', {
      'wallIndex': wallIndex,
      'locked': locked,
    });
  }

  Future<void> disposeAR() async {
    try {
      await _channel.invokeMethod<void>('disposeAR');
    } catch (_) {
      // ignore
    }
    await _eventSub?.cancel();
    _eventSub = null;
    _initialized = false;
  }

  // ── Cut Mode Methods ────────────────────────────────────────────────────

  /// Enter cut mode on the specified wall.
  /// Shows the cutting toolbar overlay.
  Future<void> enterCutMode(int wallIndex) async {
    await _channel.invokeMethod<void>(
      'enterCutMode',
      {'wallIndex': wallIndex},
    );
  }

  /// Exit cut mode and hide the cutting toolbar.
  Future<void> exitCutMode() async {
    await _channel.invokeMethod<void>('exitCutMode');
  }

  /// Smart auto-cut: user taps on a socket or switch.
  /// Vision framework detects boundary automatically.
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

  /// Manual rectangle cut using screen coordinates.
  /// Converts to wall UV space on native side.
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

  /// Manual freehand cut using a list of screen points.
  /// Points are converted to wall UV space on native side.
  Future<void> freehandCut({
    required List<Map<String, double>> screenPoints,
    required int wallIndex,
  }) async {
    await _channel.invokeMethod<void>('freehandCut', {
      'screenPoints': screenPoints,
      'wallIndex': wallIndex,
    });
  }

  /// Manual circle cut using screen coordinates.
  /// Center and radius converted to wall UV space on native side.
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

  /// Undo the last cut on the specified wall.
  /// Native side sends back cutUpdate event with new cutCount.
  Future<void> undoCut(int wallIndex) async {
    await _channel.invokeMethod<void>(
      'undoCut',
      {'wallIndex': wallIndex},
    );
  }

  /// Clear all cuts on the specified wall.
  Future<void> clearAllCuts(int wallIndex) async {
    await _channel.invokeMethod<void>(
      'clearAllCuts',
      {'wallIndex': wallIndex},
    );
  }
}
