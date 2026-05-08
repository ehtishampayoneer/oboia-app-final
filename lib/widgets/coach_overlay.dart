// lib/widgets/coach_overlay.dart
//
// OBOIA Coach Overlay System
// ──────────────────────────────────────────────────────────────────────
// A premium guided-tour overlay used throughout AR flows. Shows
// instructional text + optional animated finger pointer + optional
// progress dots, all with smooth transitions.
//
// Usage:
//   CoachController controller = CoachController();
//   controller.show(CoachStep(
//     text: "Tap the bottom-left corner of your wall",
//     pointerPosition: Alignment(-0.5, 0.7),
//     pointerGesture: PointerGesture.tap,
//     stepNumber: 1,
//     totalSteps: 3,
//   ));
//   controller.hide();
//
// Place CoachOverlay(controller: controller) somewhere high in
// your widget tree (typically inside a Stack alongside the main UI).

import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Gesture animation for the finger pointer.
enum PointerGesture {
  tap,        // single pulse
  doubleTap,  // two quick pulses
  drag,       // slides from start to end
  none,       // no animation, just a static pointer
}

/// A single coach step describing what to show.
class CoachStep {
  /// Main instruction text. Keep it short — under 10 words ideal.
  final String text;

  /// Optional secondary line, smaller text below the main one.
  final String? subtitle;

  /// Where the finger pointer should appear (or start, for drag).
  /// Use Alignment(-1, -1) for top-left, Alignment(1, 1) for bottom-right.
  /// If null, no pointer is shown.
  final Alignment? pointerPosition;

  /// For drag gestures, where the pointer ends up.
  final Alignment? pointerEndPosition;

  /// What animation the finger pointer performs.
  final PointerGesture pointerGesture;

  /// Optional step number (1-based) for progress dots.
  final int? stepNumber;

  /// Total steps in this flow, for progress dots.
  final int? totalSteps;

  /// Show a "Skip" button. Default false.
  final bool showSkip;

  /// Show a "Got it" button to advance. Default false.
  final bool showConfirm;

  /// Position of the instruction chip. Default top.
  final CoachChipPosition chipPosition;

  /// Optional auto-dismiss after this duration. If null, stays until
  /// controller.hide() is called.
  final Duration? autoDismissAfter;

  const CoachStep({
    required this.text,
    this.subtitle,
    this.pointerPosition,
    this.pointerEndPosition,
    this.pointerGesture = PointerGesture.tap,
    this.stepNumber,
    this.totalSteps,
    this.showSkip = false,
    this.showConfirm = false,
    this.chipPosition = CoachChipPosition.top,
    this.autoDismissAfter,
  });
}

enum CoachChipPosition { top, bottom, center }

/// Controller for the coach overlay. Hold onto this in your State
/// and call show/hide.
class CoachController extends ChangeNotifier {
  CoachStep? _current;
  CoachStep? get current => _current;

  VoidCallback? _onSkip;
  VoidCallback? _onConfirm;

  /// Show a coach step. Replaces any currently visible step.
  void show(
    CoachStep step, {
    VoidCallback? onSkip,
    VoidCallback? onConfirm,
  }) {
    _current = step;
    _onSkip = onSkip;
    _onConfirm = onConfirm;
    HapticFeedback.lightImpact();
    notifyListeners();
  }

  /// Hide the coach overlay entirely.
  void hide() {
    _current = null;
    _onSkip = null;
    _onConfirm = null;
    notifyListeners();
  }

  void _triggerSkip() {
    final cb = _onSkip;
    hide();
    cb?.call();
  }

  void _triggerConfirm() {
    final cb = _onConfirm;
    hide();
    cb?.call();
  }
}

/// The actual overlay widget. Place inside a Stack.
class CoachOverlay extends StatefulWidget {
  final CoachController controller;

  const CoachOverlay({
    super.key,
    required this.controller,
  });

  @override
  State<CoachOverlay> createState() => _CoachOverlayState();
}

class _CoachOverlayState extends State<CoachOverlay>
    with TickerProviderStateMixin {
  CoachStep? _displayedStep;
  late final AnimationController _fadeCtrl;
  late final AnimationController _pointerCtrl;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _pointerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    widget.controller.addListener(_onControllerChanged);
    _onControllerChanged();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _fadeCtrl.dispose();
    _pointerCtrl.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final next = widget.controller.current;
    if (next == null) {
      _fadeCtrl.reverse().then((_) {
        if (mounted) setState(() => _displayedStep = null);
      });
      return;
    }
    setState(() => _displayedStep = next);
    _fadeCtrl.forward(from: 0);

    if (next.autoDismissAfter != null) {
      Future.delayed(next.autoDismissAfter!, () {
        if (mounted && widget.controller.current == next) {
          widget.controller.hide();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = _displayedStep;
    if (step == null) return const SizedBox.shrink();

    return IgnorePointer(
      ignoring: !step.showSkip && !step.showConfirm,
      child: AnimatedBuilder(
        animation: _fadeCtrl,
        builder: (_, __) => Opacity(
          opacity: _fadeCtrl.value,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Optional finger pointer
              if (step.pointerPosition != null) _buildPointer(step),

              // Instruction chip
              _buildChip(step),
            ],
          ),
        ),
      ),
    );
  }

  // ── Instruction chip ──────────────────────────────────────────────

  Widget _buildChip(CoachStep step) {
    Widget chip = ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 14,
          ),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: AppTheme.gold.withValues(alpha: 0.5),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (step.stepNumber != null && step.totalSteps != null)
                _buildProgressDots(step.stepNumber!, step.totalSteps!),
              if (step.stepNumber != null && step.totalSteps != null)
                const SizedBox(height: 8),
              Text(
                step.text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
              if (step.subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  step.subtitle!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    height: 1.3,
                  ),
                ),
              ],
              if (step.showSkip || step.showConfirm) ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (step.showSkip)
                      _ChipButton(
                        label: 'Skip',
                        primary: false,
                        onTap: () => widget.controller._triggerSkip(),
                      ),
                    if (step.showSkip && step.showConfirm)
                      const SizedBox(width: 8),
                    if (step.showConfirm)
                      _ChipButton(
                        label: 'Got it',
                        primary: true,
                        onTap: () => widget.controller._triggerConfirm(),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );

    final padding = MediaQuery.of(context).padding;
    switch (step.chipPosition) {
      case CoachChipPosition.top:
        return Positioned(
          top: padding.top + 70,
          left: 24,
          right: 24,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: chip,
            ),
          ),
        );
      case CoachChipPosition.bottom:
        return Positioned(
          bottom: padding.bottom + 200,
          left: 24,
          right: 24,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: chip,
            ),
          ),
        );
      case CoachChipPosition.center:
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: chip,
          ),
        );
    }
  }

  Widget _buildProgressDots(int current, int total) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(total, (i) {
        final active = i < current;
        return Container(
          width: 6,
          height: 6,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: active
                ? AppTheme.gold
                : Colors.white.withValues(alpha: 0.3),
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }

  // ── Animated finger pointer ───────────────────────────────────────

  Widget _buildPointer(CoachStep step) {
    return AnimatedBuilder(
      animation: _pointerCtrl,
      builder: (_, __) {
        final t = _pointerCtrl.value;

        // Compute pointer position based on gesture
        Alignment position;
        double scale = 1.0;
        double pulseOpacity = 0.0;
        double pulseScale = 1.0;

        switch (step.pointerGesture) {
          case PointerGesture.tap:
            position = step.pointerPosition!;
            // Tap pulse: shrink slightly at t=0.5, expand ring after
            if (t < 0.4) {
              scale = 1.0 - (t / 0.4) * 0.15;
              pulseOpacity = 0.0;
            } else if (t < 0.7) {
              scale = 0.85 + ((t - 0.4) / 0.3) * 0.15;
              pulseOpacity = (t - 0.4) / 0.3;
              pulseScale = 1.0 + ((t - 0.4) / 0.3) * 1.2;
            } else {
              scale = 1.0;
              pulseOpacity = 1.0 - ((t - 0.7) / 0.3);
              pulseScale = 2.2 + ((t - 0.7) / 0.3) * 0.6;
            }
            break;

          case PointerGesture.doubleTap:
            position = step.pointerPosition!;
            // Two quick pulses
            final phase = (t * 2) % 1.0;
            if (phase < 0.3) {
              scale = 1.0 - phase / 0.3 * 0.15;
            } else if (phase < 0.5) {
              scale = 0.85 + (phase - 0.3) / 0.2 * 0.15;
              pulseOpacity = (phase - 0.3) / 0.2;
              pulseScale = 1.0 + (phase - 0.3) / 0.2 * 1.0;
            } else {
              pulseOpacity = 1.0 - (phase - 0.5) / 0.5;
              pulseScale = 2.0 + (phase - 0.5) / 0.5 * 0.5;
            }
            break;

          case PointerGesture.drag:
            final start = step.pointerPosition!;
            final end = step.pointerEndPosition ?? start;
            // Ease in-out cubic
            final eased = t < 0.5
                ? 4 * t * t * t
                : 1 - pow(-2 * t + 2, 3) / 2;
            position = Alignment(
              start.x + (end.x - start.x) * eased,
              start.y + (end.y - start.y) * eased,
            );
            // Slight press effect
            scale = 0.92;
            break;

          case PointerGesture.none:
            position = step.pointerPosition!;
            break;
        }

        return Align(
          alignment: position,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Pulse ring
              if (pulseOpacity > 0)
                Transform.scale(
                  scale: pulseScale,
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppTheme.gold.withValues(alpha: pulseOpacity),
                        width: 2,
                      ),
                    ),
                  ),
                ),
              // Finger dot
              Transform.scale(
                scale: scale,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.gold.withValues(alpha: 0.9),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.95),
                      width: 2.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// Helper because dart:math isn't imported and we only need pow for one thing
double pow(double x, int n) {
  double r = 1;
  for (int i = 0; i < n; i++) {
    r *= x;
  }
  return r;
}

// ── Internal: Chip button (Skip / Got it) ────────────────────────────

class _ChipButton extends StatelessWidget {
  final String label;
  final bool primary;
  final VoidCallback onTap;

  const _ChipButton({
    required this.label,
    required this.primary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: primary ? AppTheme.gold : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: primary
                ? AppTheme.gold
                : Colors.white.withValues(alpha: 0.3),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: primary ? Colors.black : Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
