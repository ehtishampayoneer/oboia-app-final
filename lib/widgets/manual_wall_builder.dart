// lib/widgets/manual_wall_builder.dart
//
// OBOIA Manual Wall Builder
// ──────────────────────────────────────────────────────────────────────
// Falls back from auto-detect when ARKit can't find a vertical plane.
// Guides the user through 3 taps to define a wall:
//   1. Bottom-left corner  (anchors the wall + floor line)
//   2. Bottom-right corner (gives width + floor direction)
//   3. Top-right corner    (gives height)
//
// Each tap is raycast into world space by native code. The 3 world
// points fully define a wall plane, which we send back to native to
// create a "manual wall anchor" — same downstream pipeline as a real
// ARPlaneAnchor (PBR materials, cuts, measurements, etc).
//
// Usage:
//   ManualWallBuilder(
//     coachController: _coach,
//     onScreenTap: (point) async {
//       // Forward screen tap to native, get back a 3D world point.
//       return await ARService.instance.raycastToWorld(point);
//     },
//     onWallDefined: (corners) async {
//       await ARService.instance.defineManualWall(corners);
//     },
//     onCancel: () {
//       // Return to auto-detect mode
//     },
//   );

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'coach_overlay.dart';

/// A 3D point returned by the native raycast, expressed in metres
/// relative to ARKit world origin.
class WorldPoint {
  final double x;
  final double y;
  final double z;
  /// The screen point the user tapped (used for drawing markers).
  final Offset screenPoint;

  const WorldPoint({
    required this.x,
    required this.y,
    required this.z,
    required this.screenPoint,
  });

  Map<String, dynamic> toMap() => {'x': x, 'y': y, 'z': z};

  static WorldPoint? fromNative(Map<String, dynamic>? data, Offset screen) {
    if (data == null) return null;
    final x = (data['x'] as num?)?.toDouble();
    final y = (data['y'] as num?)?.toDouble();
    final z = (data['z'] as num?)?.toDouble();
    if (x == null || y == null || z == null) return null;
    return WorldPoint(x: x, y: y, z: z, screenPoint: screen);
  }
}

/// Callback signatures
typedef ScreenTapToWorld = Future<WorldPoint?> Function(Offset screenPoint);
typedef WallDefinedCallback = Future<void> Function(List<WorldPoint> corners);

class ManualWallBuilder extends StatefulWidget {
  /// Coach controller (shared with the rest of the AR screen).
  final CoachController coachController;

  /// Forward a screen tap to native AR, receive a world-space point.
  /// Returns null if the raycast didn't hit a real-world surface
  /// (e.g. user tapped on the sky).
  final ScreenTapToWorld onScreenTap;

  /// Called once 3 corners are captured AND the user confirms.
  /// Receives [bottomLeft, bottomRight, topRight].
  final WallDefinedCallback onWallDefined;

  /// User cancelled — return to auto-detect mode.
  final VoidCallback onCancel;

  const ManualWallBuilder({
    super.key,
    required this.coachController,
    required this.onScreenTap,
    required this.onWallDefined,
    required this.onCancel,
  });

  @override
  State<ManualWallBuilder> createState() => _ManualWallBuilderState();
}

class _ManualWallBuilderState extends State<ManualWallBuilder>
    with SingleTickerProviderStateMixin {
  /// The captured corners so far. Order: bottomLeft, bottomRight, topRight.
  final List<WorldPoint> _corners = [];

  /// True while a tap is being raycast (prevents double-taps).
  bool _busy = false;

  /// True once user has tapped 3 corners and we're awaiting confirmation.
  bool _awaitingConfirm = false;

  /// Animation for marker pulse + connecting line draw.
  late final AnimationController _animCtrl;

  static const _maxCorners = 3;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    // Show first instruction as soon as widget mounts.
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateCoach());
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  // ── Coach updates ─────────────────────────────────────────────────

  void _updateCoach() {
    if (!mounted) return;

    final step = _corners.length;

    if (_awaitingConfirm) {
      widget.coachController.show(
        const CoachStep(
          text: 'Looks good?',
          subtitle: 'Tap Confirm to set this wall, or Undo to redo.',
          stepNumber: 3,
          totalSteps: 3,
          chipPosition: CoachChipPosition.top,
        ),
      );
      return;
    }

    switch (step) {
      case 0:
        widget.coachController.show(
          const CoachStep(
            text: 'Tap the bottom-left corner of your wall',
            subtitle: 'Where the wall meets the floor on the left',
            pointerPosition: Alignment(-0.5, 0.45),
            pointerGesture: PointerGesture.tap,
            stepNumber: 1,
            totalSteps: 3,
          ),
        );
        break;
      case 1:
        widget.coachController.show(
          const CoachStep(
            text: 'Now tap the bottom-right corner',
            subtitle: 'Where the wall meets the floor on the right',
            pointerPosition: Alignment(0.5, 0.45),
            pointerGesture: PointerGesture.tap,
            stepNumber: 2,
            totalSteps: 3,
          ),
        );
        break;
      case 2:
        widget.coachController.show(
          const CoachStep(
            text: 'Last one — tap the top-right corner',
            subtitle: 'Where the wall meets the ceiling',
            pointerPosition: Alignment(0.5, -0.4),
            pointerGesture: PointerGesture.tap,
            stepNumber: 3,
            totalSteps: 3,
          ),
        );
        break;
    }
  }

  // ── Tap handling ──────────────────────────────────────────────────

  Future<void> _handleTap(TapUpDetails details) async {
    if (_busy || _awaitingConfirm) return;
    if (_corners.length >= _maxCorners) return;

    setState(() => _busy = true);

    final tapPoint = details.localPosition;
    final world = await widget.onScreenTap(tapPoint);

    if (!mounted) return;

    if (world == null) {
      // Raycast failed — show a helpful nudge
      HapticFeedback.heavyImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            "Couldn't detect that surface. Try tapping a clearly visible spot on the wall or floor.",
          ),
          backgroundColor: Colors.black87,
          duration: const Duration(seconds: 2),
        ),
      );
      setState(() => _busy = false);
      return;
    }

    HapticFeedback.lightImpact();
    setState(() {
      _corners.add(world);
      _busy = false;
      if (_corners.length == _maxCorners) {
        _awaitingConfirm = true;
      }
    });
    _updateCoach();
  }

  Future<void> _undo() async {
    if (_corners.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() {
      _corners.removeLast();
      _awaitingConfirm = false;
    });
    _updateCoach();
  }

  Future<void> _confirm() async {
    if (_corners.length != _maxCorners) return;
    HapticFeedback.mediumImpact();
    widget.coachController.hide();
    await widget.onWallDefined(List.unmodifiable(_corners));
  }

  Future<void> _cancel() async {
    HapticFeedback.lightImpact();
    widget.coachController.hide();
    widget.onCancel();
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).padding;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Capture taps
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: _handleTap,
            child: const SizedBox.expand(),
          ),
        ),

        // Marker + line layer (draws on top of AR)
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _animCtrl,
              builder: (_, __) => CustomPaint(
                painter: _CornerPainter(
                  corners: _corners
                      .map((c) => c.screenPoint)
                      .toList(growable: false),
                  pulseValue: _animCtrl.value,
                  isComplete: _awaitingConfirm,
                  goldColor: AppTheme.gold,
                ),
              ),
            ),
          ),
        ),

        // Top status pill
        Positioned(
          top: padding.top + 12,
          left: 16,
          right: 16,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _ManualPill(
                onTap: _cancel,
                icon: Icons.arrow_back,
                label: 'Cancel',
              ),
              _ProgressBadge(
                current: _awaitingConfirm ? 3 : _corners.length,
                total: _maxCorners,
              ),
            ],
          ),
        ),

        // Bottom action bar (Undo + Confirm)
        if (_corners.isNotEmpty)
          Positioned(
            bottom: padding.bottom + 28,
            left: 0,
            right: 0,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ActionButton(
                    icon: Icons.undo,
                    label: 'Undo',
                    primary: false,
                    onTap: _undo,
                  ),
                  if (_awaitingConfirm) ...[
                    const SizedBox(width: 12),
                    _ActionButton(
                      icon: Icons.check,
                      label: 'Confirm',
                      primary: true,
                      onTap: _confirm,
                    ),
                  ],
                ],
              ),
            ),
          ),

        // Busy spinner during raycast
        if (_busy)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: AppTheme.gold,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Custom painter for corner markers + connecting lines ─────────────

class _CornerPainter extends CustomPainter {
  final List<Offset> corners;
  final double pulseValue;
  final bool isComplete;
  final Color goldColor;

  _CornerPainter({
    required this.corners,
    required this.pulseValue,
    required this.isComplete,
    required this.goldColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.isEmpty) return;

    // Draw connecting lines first (so markers render on top)
    if (corners.length >= 2) {
      final linePaint = Paint()
        ..color = goldColor.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;

      // Bottom edge
      canvas.drawLine(corners[0], corners[1], linePaint);

      if (corners.length >= 3) {
        // Right edge
        canvas.drawLine(corners[1], corners[2], linePaint);

        if (isComplete) {
          // Compute implied top-left corner = bottomLeft + (topRight - bottomRight)
          final implied = corners[0] + (corners[2] - corners[1]);
          // Top edge
          canvas.drawLine(corners[2], implied, linePaint);
          // Left edge
          canvas.drawLine(implied, corners[0], linePaint);

          // Subtle gold fill
          final fillPaint = Paint()
            ..color = goldColor.withValues(alpha: 0.08)
            ..style = PaintingStyle.fill;
          final path = Path()
            ..moveTo(corners[0].dx, corners[0].dy)
            ..lineTo(corners[1].dx, corners[1].dy)
            ..lineTo(corners[2].dx, corners[2].dy)
            ..lineTo(implied.dx, implied.dy)
            ..close();
          canvas.drawPath(path, fillPaint);
        }
      }
    }

    // Draw markers on top
    for (int i = 0; i < corners.length; i++) {
      _drawMarker(canvas, corners[i], i + 1);
    }
  }

  void _drawMarker(Canvas canvas, Offset point, int number) {
    // Outer pulsing ring
    final pulseRadius = 18.0 + pulseValue * 8.0;
    final pulseOpacity = (1.0 - pulseValue) * 0.6;
    final pulsePaint = Paint()
      ..color = goldColor.withValues(alpha: pulseOpacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(point, pulseRadius, pulsePaint);

    // Solid center dot
    final centerPaint = Paint()
      ..color = goldColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(point, 14, centerPaint);

    // White border
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(point, 14, borderPaint);

    // Number
    final tp = TextPainter(
      text: TextSpan(
        text: '$number',
        style: const TextStyle(
          color: Colors.black,
          fontWeight: FontWeight.w800,
          fontSize: 13,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, point - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _CornerPainter old) =>
      old.corners != corners ||
      old.pulseValue != pulseValue ||
      old.isComplete != isComplete;
}

// ── Top pills + bottom buttons ───────────────────────────────────────

class _ManualPill extends StatelessWidget {
  final VoidCallback onTap;
  final IconData icon;
  final String label;

  const _ManualPill({
    required this.onTap,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.2),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressBadge extends StatelessWidget {
  final int current;
  final int total;

  const _ProgressBadge({required this.current, required this.total});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.gold,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$current of $total',
        style: const TextStyle(
          color: Colors.black,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.primary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: primary
              ? AppTheme.gold
              : Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: primary
                ? AppTheme.gold
                : Colors.white.withValues(alpha: 0.25),
          ),
          boxShadow: primary
              ? [
                  BoxShadow(
                    color: AppTheme.gold.withValues(alpha: 0.4),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: primary ? Colors.black : Colors.white,
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: primary ? Colors.black : Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
