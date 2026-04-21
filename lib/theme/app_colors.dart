import 'package:flutter/material.dart';

/// OBOIA brand palette. Single source of truth for colors.
class AppColors {
  AppColors._();

  // Backgrounds
  static const Color background = Color(0xFF0A0A0A);
  static const Color card = Color(0xFF141414);
  static const Color surface = Color(0xFF1A1A1A);
  static const Color surfaceHigh = Color(0xFF242424);

  // Gold accents
  static const Color gold = Color(0xFFFFD369);
  static const Color goldSecondary = Color(0xFFF5C842);
  static const Color goldMuted = Color(0x33FFD369); // 20% gold

  // Text
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF8A8A8A);
  static const Color textTertiary = Color(0xFF5A5A5A);

  // Status
  static const Color success = Color(0xFF4CAF50);
  static const Color error = Color(0xFFFF5252);
  static const Color warning = Color(0xFFFFA726);
  static const Color info = Color(0xFF42A5F5);

  // Borders / dividers
  static const Color border = Color(0xFF262626);
  static const Color borderGold = Color(0x66FFD369); // 40% gold
}
