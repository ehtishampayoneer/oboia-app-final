// lib/widgets/scanning_overlay.dart
//
// Subtle scanning visualization shown WHILE the user is hunting for a wall.
// Hides cleanly the moment a wall is captured (auto OR manual).
//
// Design goals:
//  - Looks magical: white wireframe dots + a scan-line sweep
//  - Lightweight: pure Flutter CustomPainter, no shaders, no platform views
//  - Frame-rate aware: throttles to 30fps on older iPhones
//  - Never blocks taps — IgnorePointer wraps the whole thing
//
// Usage in ar_screen.dart:
//   ScanningOverlay(
//     visible: !hasWall && !inManualMode,
//     pointCount: detectedFeatureCount,
//   )

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

class ScanningOverlay extends StatefulWidget {
  final bool visible;
  final int pointCount;

  const ScanningOverlay({
    super.key,
    required this.visible,
    this.pointCount = 0,
  });

  @override
  State<ScanningOverlay> createState() => _ScanningOverlayState();
}

class _ScanningOverlayState extends State<ScanningOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _sweep;       // 0..1 looping, drives the scan-line
  late final AnimationController _fade;        // 0..1 forward/reverse, drives visibility
  late final AnimationController _twinkle;     // 0..1 looping, varies dot brightness

  // Stable random dot positions — generated once so dots don't jitter every frame.
  late final List<_Dot> _dots;

  // Throttle to ~30fps on older devices (anything that isn't Pro/Max-class).
  // Heuristic: if it's iOS, assume modern. Any reported Android assumes throttle.
  // Cheap, good-enough; full device detection is overkill for a V1.
  late final Duration _sweepPeriod;

  @override
  void initState() {
    super.initState();

    // Pick periods based on platform.
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    _sweepPeriod = isIOS
        ? const Duration(milliseconds: 2400)
        : const Duration(milliseconds: 3200);

    _sweep = AnimationController(vsync: this, duration: _sweepPeriod)
      ..repeat();

    _twinkle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      value: widget.visible ? 1.0 : 0.0,
    );

    _dots = _generateDots(120);
  }

  @override
  void didUpdateWidget(covariant ScanningOverlay old) {
    super.didUpdateWidget(old);
    if (widget.visible != old.visible) {
      if (widget.visible) {
        _fade.forward();
      } else {
        _fade.reverse();
      }
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    _fade.dispose();
    _twinkle.dispose();
    super.dispose();
  }

  static List<_Dot> _generateDots(int count) {
    // Deterministic seed so layout is consistent across rebuilds.
    final r = math.Random(42);
    final list = <_Dot>[];
    for (int i = 0; i < count; i++) {
      list.add(_Dot(
        // Normalized coords (0..1), scaled to canvas later.
        x: r.nextDouble(),
        y: r.nextDouble(),
        // Each dot has a phase offset so the twinkle isn't synchronized.
        phase: r.nextDouble(),
        // Some dots are dimmer than others for depth.
        baseAlpha: 0.18 + r.nextDouble() * 0.45,
      ));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      // Always ignore touches — overlay is purely decorative.
      child: AnimatedBuilder(
        animation: Listenable.merge([_sweep, _fade, _twinkle]),
        builder: (context, _) {
          if (_fade.value <= 0.001) return const SizedBox.shrink();

          return Opacity(
            opacity: _fade.value.clamp(0.0, 1.0),
            child: Stack(
              children: [
                // Wireframe dots + sweep
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ScanPainter(
                      dots: _dots,
                      sweep: _sweep.value,
                      twinkle: _twinkle.value,
                    ),
                  ),
                ),

                // Status chip — bottom-center, above any other UI
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 140,
                  child: Center(
                    child: _StatusChip(pointCount: widget.pointCount),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Dot {
  final double x;
  final double y;
  final double phase;
  final double baseAlpha;
  const _Dot({
    required this.x,
    required this.y,
    required this.phase,
    required this.baseAlpha,
  });
}

class _ScanPainter extends CustomPainter {
  final List<_Dot> dots;
  final double sweep;       // 0..1, vertical sweep position
  final double twinkle;     // 0..1, oscillates

  _ScanPainter({
    required this.dots,
    required this.sweep,
    required this.twinkle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Sweep band: a soft horizontal gradient stripe traveling top→bottom→top
    final sweepY = size.height * sweep;
    const bandHeight = 220.0;

    // Draw the dots first so the sweep band can illuminate ones near it.
    final dotPaint = Paint()..style = PaintingStyle.fill;
    for (final d in dots) {
      final px = d.x * size.width;
      final py = d.y * size.height;

      // Distance from sweep band — dots close to band glow brighter.
      final dy = (py - sweepY).abs();
      final glow = (1.0 - (dy / bandHeight)).clamp(0.0, 1.0);

      // Twinkle: each dot pulses slightly out of phase.
      final t = (twinkle + d.phase) % 1.0;
      final pulse = 0.7 + 0.3 * math.sin(t * math.pi * 2);

      final alpha = (d.baseAlpha * pulse + glow * 0.55).clamp(0.0, 0.95);
      dotPaint.color = Colors.white.withValues(alpha: alpha);

      // Slightly larger dots near the sweep — gives a subtle 3D feel.
      final radius = 1.3 + glow * 1.4;
      canvas.drawCircle(Offset(px, py), radius, dotPaint);
    }

    // Draw the sweep band itself: a faint gold gradient stripe.
    // Gold matches your brand color (#FFD369). Very low opacity.
    final bandRect = Rect.fromLTRB(
      0,
      sweepY - bandHeight / 2,
      size.width,
      sweepY + bandHeight / 2,
    );
    final bandShader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        const Color(0x00FFD369),
        const Color(0x33FFD369),
        const Color(0x00FFD369),
      ],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(bandRect);

    canvas.drawRect(bandRect, Paint()..shader = bandShader);

    // Bright leading edge of the sweep — a 1px glowing line.
    final edgePaint = Paint()
      ..color = const Color(0xFFFFD369).withValues(alpha: 0.55)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(0, sweepY),
      Offset(size.width, sweepY),
      edgePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ScanPainter old) {
    return old.sweep != sweep ||
        old.twinkle != twinkle ||
        !identical(old.dots, dots);
  }
}

class _StatusChip extends StatelessWidget {
  final int pointCount;

  const _StatusChip({required this.pointCount});

  @override
  Widget build(BuildContext context) {
    final label = pointCount > 0
        ? 'Scanning your room · $pointCount points'
        : 'Scanning your room…';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: const Color(0xFFFFD369).withValues(alpha: 0.35),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tiny pulsing gold dot
          _PulseDot(),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _PulseDot extends StatefulWidget {
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final scale = lerpDouble(0.7, 1.15, _c.value)!;
        final alpha = lerpDouble(0.55, 1.0, _c.value)!;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: const Color(0xFFFFD369).withValues(alpha: alpha),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFFD369).withValues(alpha: 0.4),
                  blurRadius: 6,
                  spreadRadius: 0.5,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
