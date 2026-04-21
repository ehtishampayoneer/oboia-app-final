import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../services/auth_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/custom_button.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _googleLoading = false;

  Future<void> _googleSignIn() async {
    setState(() => _googleLoading = true);
    try {
      final user = await AuthService.instance.signInWithGoogle();
      if (user == null) return; // cancelled
      if (!mounted) return;
      // router redirect handles destination
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Google sign-in failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _googleLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              _logo()
                  .animate()
                  .scale(
                    duration: 500.ms,
                    begin: const Offset(0.8, 0.8),
                    curve: Curves.easeOutBack,
                  )
                  .fadeIn(),
              const SizedBox(height: 32),
              const Text(
                'Welcome to OBOIA',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ).animate().fadeIn(delay: 200.ms),
              const SizedBox(height: 12),
              const Text(
                'Discover stunning wallpapers and preview them\non your walls — instantly, in AR.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
              ).animate().fadeIn(delay: 400.ms),
              const Spacer(flex: 2),
              CustomButton(
                label: 'Continue with Google',
                icon: Icons.g_mobiledata_rounded,
                loading: _googleLoading,
                onPressed: _googleSignIn,
              ).animate().fadeIn(delay: 500.ms).moveY(begin: 20, end: 0),
              const SizedBox(height: 12),
              CustomButton(
                label: 'Sign up with Email',
                variant: ButtonVariant.outline,
                icon: Icons.mail_outline_rounded,
                onPressed: () => context.push('/signup'),
              ).animate().fadeIn(delay: 650.ms).moveY(begin: 20, end: 0),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Already have an account? ',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  GestureDetector(
                    onTap: () => context.push('/login'),
                    child: const Text(
                      'Sign in',
                      style: TextStyle(
                        color: AppColors.gold,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ).animate().fadeIn(delay: 800.ms),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _logo() {
    return Center(
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const RadialGradient(
            colors: [AppColors.gold, AppColors.goldSecondary],
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.gold.withOpacity(0.3),
              blurRadius: 30,
              spreadRadius: 2,
            ),
          ],
        ),
        child: const Center(
          child: Text(
            'O',
            style: TextStyle(
              color: Colors.black,
              fontSize: 48,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ),
    );
  }
}
