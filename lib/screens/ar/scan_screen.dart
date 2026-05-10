// lib/screens/ar/scan_screen.dart
//
// Phase 1 — Room Scan screen.
//
// User opens the AR feature → lands HERE FIRST (not on the wallpaper screen).
// Apple's RoomPlan (LiDAR) detects walls, doors, windows, openings, and
// furniture in real time. The user sees animated outlines and can tap any
// item to toggle whether it should be excluded from wallpaper application.
//
// When the user taps "Done Scanning", we navigate to the wallpaper screen
// (existing ar_screen.dart, soon to be modified in Patch 1.7) carrying the
// final ScanSnapshot as a navigation argument.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/ar_service.dart';

// ─────────────────────────────────────────────────────────────────────────
// Data models — mirror the Swift side
// ─────────────────────────────────────────────────────────────────────────

class DetectedSurface {
  final String id;
  final String kind; // wall | door | window | opening
  final double width;
  final double height;
  final double sqm;
  final double confidence;
  final bool isExcluded;

  const DetectedSurface({
    required this.id,
    required this.kind,
    required this.width,
    required this.height,
    required this.sqm,
    required this.confidence,
    required this.isExcluded,
  });

  factory DetectedSurface.fromMap(Map<String, dynamic> m) {
    return DetectedSurface(
      id: (m['id'] ?? '').toString(),
      kind: (m['kind'] ?? 'wall').toString(),
      width: (m['width'] as num?)?.toDouble() ?? 0,
      height: (m['height'] as num?)?.toDouble() ?? 0,
      sqm: (m['sqm'] as num?)?.toDouble() ?? 0,
      confidence: (m['confidence'] as num?)?.toDouble() ?? 0,
      isExcluded: m['isExcluded'] as bool? ?? false,
    );
  }
}

class DetectedObject {
  final String id;
  final String category;
  final double confidence;
  final bool isExcluded;

  const DetectedObject({
    required this.id,
    required this.category,
    required this.confidence,
    required this.isExcluded,
  });

  factory DetectedObject.fromMap(Map<String, dynamic> m) {
    return DetectedObject(
      id: (m['id'] ?? '').toString(),
      category: (m['category'] ?? '').toString(),
      confidence: (m['confidence'] as num?)?.toDouble() ?? 0,
      isExcluded: m['isExcluded'] as bool? ?? true,
    );
  }
}

class ScanSnapshot {
  final List<DetectedSurface> surfaces;
  final List<DetectedObject> objects;
  final bool isFinal;

  const ScanSnapshot({
    required this.surfaces,
    required this.objects,
    required this.isFinal,
  });

  factory ScanSnapshot.fromMap(Map<String, dynamic> m) {
    final rawSurfaces = (m['surfaces'] as List?) ?? const [];
    final rawObjects = (m['objects'] as List?) ?? const [];
    return ScanSnapshot(
      surfaces: rawSurfaces
          .whereType<Map>()
          .map((e) => DetectedSurface.fromMap(e.map((k, v) => MapEntry(k.toString(), v))))
          .toList(),
      objects: rawObjects
          .whereType<Map>()
          .map((e) => DetectedObject.fromMap(e.map((k, v) => MapEntry(k.toString(), v))))
          .toList(),
      isFinal: m['isFinal'] as bool? ?? false,
    );
  }

  int get wallCount => surfaces.where((s) => s.kind == 'wall').length;
  int get doorCount => surfaces.where((s) => s.kind == 'door').length;
  int get windowCount => surfaces.where((s) => s.kind == 'window').length;
}

// ─────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _ar = ARService.instance;
  StreamSubscription<AREvent>? _sub;

  ScanSnapshot _latest = const ScanSnapshot(
    surfaces: [],
    objects: [],
    isFinal: false,
  );

  String? _instruction; // RoomPlan coaching text
  bool _scanStarted = false;
  bool _scanFinishing = false;
  String? _errorMessage;

  // Coaching messages we cycle through if no native instruction is delivered
  static const List<String> _idleCoaching = [
    'Walk slowly around the room',
    'Point the camera at every wall',
    'Hold the phone at chest height',
    'Move the phone smoothly — no fast turns',
    'Make sure the room is well lit',
  ];
  int _coachingIndex = 0;
  Timer? _coachingTimer;

  @override
  void initState() {
    super.initState();
    _initEvents();
    _startScan();
    _startCoachingTicker();
  }

  Future<void> _initEvents() async {
    await _ar.initAR();
    _sub = _ar.events.listen(_onAREvent);
  }

  Future<void> _startScan() async {
    try {
      await _ar.startScan();
      setState(() => _scanStarted = true);
    } on PlatformException catch (e) {
      setState(() {
        _errorMessage = e.message ?? 'Failed to start scan.';
      });
    } catch (e) {
      setState(() => _errorMessage = e.toString());
    }
  }

  void _startCoachingTicker() {
    _coachingTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _instruction != null) return;
      setState(() {
        _coachingIndex = (_coachingIndex + 1) % _idleCoaching.length;
      });
    });
  }

  void _onAREvent(AREvent ev) {
    switch (ev.type) {
      case 'scanStarted':
        if (mounted) setState(() => _scanStarted = true);
        break;

      case 'scanUpdate':
        final snap = ScanSnapshot.fromMap(ev.data);
        if (mounted) setState(() => _latest = snap);
        break;

      case 'scanInstruction':
        final raw = ev.data['instruction'] as String?;
        if (raw == null) return;
        if (mounted) setState(() => _instruction = _humanizeInstruction(raw));
        break;

      case 'scanComplete':
        final snap = ScanSnapshot.fromMap(ev.data);
        if (mounted) {
          setState(() {
            _latest = snap;
            _scanFinishing = false;
          });
          _navigateToWallpaperScreen(snap);
        }
        break;

      case 'scanFailed':
        if (mounted) {
          setState(() {
            _scanFinishing = false;
            _errorMessage = ev.data['message']?.toString() ?? 'Scan failed.';
          });
        }
        break;
    }
  }

  String _humanizeInstruction(String raw) {
    // RoomCaptureSession.Instruction prints like "RoomCaptureSession.Instruction.normal"
    // We translate to friendlier copy.
    final lower = raw.toLowerCase();
    if (lower.contains('movecloser')) return 'Move closer to the wall';
    if (lower.contains('movefurther')) return 'Step back a little';
    if (lower.contains('moreambient')) return 'Move to a brighter spot';
    if (lower.contains('slow')) return 'Slow down — move the phone gently';
    if (lower.contains('lowtexture')) return 'Point at a more detailed surface';
    if (lower.contains('lowlight')) return 'Lighting is too dim';
    if (lower.contains('normal')) return 'Looking good — keep scanning';
    return null ?? 'Keep scanning';
  }

  Future<void> _stopAndFinish() async {
    if (_scanFinishing) return;
    setState(() => _scanFinishing = true);
    try {
      await _ar.stopScan();
      // We DON'T navigate immediately. We wait for the scanComplete event
      // because the final snapshot only arrives when RoomPlan finishes
      // post-processing. Stop is a request, scanComplete is the answer.
    } on PlatformException catch (e) {
      setState(() {
        _scanFinishing = false;
        _errorMessage = e.message ?? 'Failed to stop scan.';
      });
    }
  }

  void _navigateToWallpaperScreen(ScanSnapshot snap) {
    // Navigation deferred to Patch 1.7 (modifies ar_screen.dart to accept
    // a ScanSnapshot). For now, just pop with the result so Patch 1.7's
    // caller can decide what to do.
    if (!mounted) return;
    Navigator.of(context).pop<ScanSnapshot>(snap);
  }

  Future<void> _toggleSurfaceExclusion(DetectedSurface s) async {
    try {
      await _ar.toggleSurfaceExclusion(s.id);
    } on PlatformException catch (_) {
      // Ignore — UI will refresh on next scanUpdate.
    }
  }

  @override
  void dispose() {
    _coachingTimer?.cancel();
    _sub?.cancel();
    if (_scanStarted && !_scanFinishing) {
      // User backed out — make sure native scan stops.
      _ar.stopScan();
    }
    super.dispose();
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // The AR camera feed lives inside the existing native AR view.
          // Phase 1 reuses ARWallpaperView (which now starts in scanning mode).
          const _ARNativeView(),

          // Top instructional pill
          _CoachingPill(
            text: _instruction ?? _idleCoaching[_coachingIndex],
          ),

          // Top-left back button
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            child: _RoundButton(
              icon: Icons.arrow_back,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),

          // Right-side detected items legend
          if (_latest.surfaces.isNotEmpty || _latest.objects.isNotEmpty)
            Positioned(
              top: MediaQuery.of(context).padding.top + 80,
              right: 12,
              child: _DetectedLegend(
                snapshot: _latest,
                onTapSurface: _toggleSurfaceExclusion,
              ),
            ),

          // Error banner
          if (_errorMessage != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 80,
              left: 12,
              right: 80,
              child: _ErrorBanner(
                message: _errorMessage!,
                onDismiss: () => setState(() => _errorMessage = null),
              ),
            ),

          // Bottom — Done button + status
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 24,
            left: 0,
            right: 0,
            child: Center(
              child: _DoneButton(
                enabled: _latest.wallCount >= 1 && !_scanFinishing,
                isWorking: _scanFinishing,
                wallCount: _latest.wallCount,
                onTap: _stopAndFinish,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Native AR view embedding
// ─────────────────────────────────────────────────────────────────────────

class _ARNativeView extends StatelessWidget {
  const _ARNativeView();

  @override
  Widget build(BuildContext context) {
    return const UiKitView(
      viewType: 'com.oboia/ar_view',
      creationParams: <String, dynamic>{},
      creationParamsCodec: StandardMessageCodec(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────

class _CoachingPill extends StatelessWidget {
  final String text;
  const _CoachingPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 16,
      left: 60,
      right: 60,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        child: Container(
          key: ValueKey(text),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: const Color(0xFFFFD369).withValues(alpha: 0.4),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.camera_alt_outlined,
                  color: Color(0xFFFFD369), size: 16),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}

class _DetectedLegend extends StatelessWidget {
  final ScanSnapshot snapshot;
  final void Function(DetectedSurface) onTapSurface;

  const _DetectedLegend({
    required this.snapshot,
    required this.onTapSurface,
  });

  @override
  Widget build(BuildContext context) {
    final walls = snapshot.surfaces.where((s) => s.kind == 'wall').toList();
    final doors = snapshot.surfaces.where((s) => s.kind == 'door').toList();
    final windows = snapshot.surfaces.where((s) => s.kind == 'window').toList();

    return Container(
      width: 150,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Detected',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          if (walls.isNotEmpty) ...[
            for (int i = 0; i < walls.length; i++)
              _LegendRow(
                label: 'Wall ${i + 1}',
                detail: '${walls[i].sqm.toStringAsFixed(1)} m²',
                color: const Color(0xFFFFD369),
                isExcluded: walls[i].isExcluded,
                onTap: () => onTapSurface(walls[i]),
              ),
          ],
          if (doors.isNotEmpty) ...[
            const SizedBox(height: 4),
            for (int i = 0; i < doors.length; i++)
              _LegendRow(
                label: 'Door ${i + 1}',
                detail: 'excluded',
                color: const Color(0xFFE57373),
                isExcluded: doors[i].isExcluded,
                onTap: () => onTapSurface(doors[i]),
              ),
          ],
          if (windows.isNotEmpty) ...[
            const SizedBox(height: 4),
            for (int i = 0; i < windows.length; i++)
              _LegendRow(
                label: 'Window ${i + 1}',
                detail: 'excluded',
                color: const Color(0xFF64B5F6),
                isExcluded: windows[i].isExcluded,
                onTap: () => onTapSurface(windows[i]),
              ),
          ],
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  final String label;
  final String detail;
  final Color color;
  final bool isExcluded;
  final VoidCallback onTap;

  const _LegendRow({
    required this.label,
    required this.detail,
    required this.color,
    required this.isExcluded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(top: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isExcluded
              ? Colors.white.withValues(alpha: 0.04)
              : color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isExcluded
                ? Colors.white24
                : color.withValues(alpha: 0.6),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(width: 8, height: 8,
              decoration: BoxDecoration(
                color: isExcluded ? Colors.white24 : color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                    style: TextStyle(
                      color: isExcluded ? Colors.white54 : Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      decoration: isExcluded
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                    ),
                  ),
                  Text(detail,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DoneButton extends StatelessWidget {
  final bool enabled;
  final bool isWorking;
  final int wallCount;
  final VoidCallback onTap;

  const _DoneButton({
    required this.enabled,
    required this.isWorking,
    required this.wallCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final canTap = enabled && !isWorking;
    return GestureDetector(
      onTap: canTap ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        decoration: BoxDecoration(
          color: canTap
              ? const Color(0xFFFFD369)
              : Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(28),
          boxShadow: canTap
              ? [
                  BoxShadow(
                    color: const Color(0xFFFFD369).withValues(alpha: 0.4),
                    blurRadius: 16,
                    spreadRadius: 0,
                  ),
                ]
              : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isWorking) ...[
              const SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.black,
                ),
              ),
              const SizedBox(width: 10),
              const Text('Finishing scan…',
                  style: TextStyle(color: Colors.black,
                      fontWeight: FontWeight.w700)),
            ] else ...[
              Icon(
                wallCount > 0 ? Icons.check_circle : Icons.hourglass_empty,
                color: canTap ? Colors.black : Colors.white54,
                size: 18,
              ),
              const SizedBox(width: 10),
              Text(
                wallCount > 0
                    ? 'Done — $wallCount ${wallCount == 1 ? "wall" : "walls"} found'
                    : 'Looking for walls…',
                style: TextStyle(
                  color: canTap ? Colors.black : Colors.white54,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;
  const _ErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white, size: 16),
            onPressed: onDismiss,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
