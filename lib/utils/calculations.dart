import 'dart:math' as math;

/// Core calculation engine for OBOIA.
/// THESE FORMULAS MUST NEVER CHANGE — they are part of the business contract
/// with the web dashboard.
class Calc {
  Calc._();

  /// Square meters of a wall from width × height (both in meters).
  static double sqm(double widthMeters, double heightMeters) {
    if (widthMeters <= 0 || heightMeters <= 0) return 0;
    return widthMeters * heightMeters;
  }

  /// Rolls needed for a wall, rounded UP to the nearest whole roll.
  ///
  ///   rolls = ceil( sqm / (rollWidth × rollLength) )
  static int rollsNeeded({
    required double wallWidthMeters,
    required double wallHeightMeters,
    required double rollWidthMeters,
    required double rollLengthMeters,
  }) {
    final area = sqm(wallWidthMeters, wallHeightMeters);
    final rollCoverage = rollWidthMeters * rollLengthMeters;
    if (rollCoverage <= 0 || area <= 0) return 0;
    return (area / rollCoverage).ceil();
  }

  /// Total price = rolls × pricePerRoll.
  static double totalPrice({
    required int rolls,
    required double pricePerRoll,
  }) {
    if (rolls <= 0 || pricePerRoll <= 0) return 0;
    return rolls * pricePerRoll;
  }

  /// Clamp helper for safely restricting values to a range.
  static double clamp(double v, double lo, double hi) =>
      math.max(lo, math.min(hi, v));
}
