import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../theme/app_colors.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Timer(const Duration(seconds: 2), _decideNext);
  }

  void _decideNext() {
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    if (auth.loading) {
      Timer(const Duration(milliseconds: 500), _decideNext);
      return;
    }
    if (!auth.isSignedIn) {
      context.go('/welcome');
    } else if (auth.isCraftsman) {
      context.go('/craftsman');
    } else {
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const RadialGradient(
                  colors: [AppColors.gold, AppColors.goldSecondary],
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.gold.withOpacity(0.35),
                    blurRadius: 40,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: const Center(
                child: Text(
                  'O',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 56,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -2,
                  ),
                ),
              ),
            )
                .animate()
                .scale(
                  duration: 700.ms,
                  curve: Curves.easeOutBack,
                  begin: const Offset(0.6, 0.6),
                )
                .fadeIn(duration: 500.ms),
            const SizedBox(height: 24),
            const Text(
              'OBOIA',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 32,
                fontWeight: FontWeight.w900,
                letterSpacing: 8,
              ),
            ).animate().fadeIn(delay: 300.ms, duration: 600.ms),
            const SizedBox(height: 8),
            const Text(
              'Premium wallpaper, previewed in AR',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ).animate().fadeIn(delay: 600.ms, duration: 600.ms),
          ],
        ),
      ),
    );
  }
}
