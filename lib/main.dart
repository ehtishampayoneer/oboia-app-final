import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'firebase_options.dart';
import 'providers/auth_provider.dart';
import 'providers/cart_provider.dart';
import 'providers/shop_provider.dart';
import 'screens/ar/ar_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/auth/welcome_screen.dart';
import 'screens/cart/cart_screen.dart';
import 'screens/cart/order_confirm_screen.dart';
import 'screens/craftsman/craftsman_bonus_screen.dart';
import 'screens/craftsman/craftsman_home_screen.dart';
import 'screens/craftsman/craftsman_jobs_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/orders/order_detail_screen.dart';
import 'screens/orders/orders_screen.dart';
import 'screens/profile/profile_screen.dart';
import 'screens/shop/shop_screen.dart';
import 'screens/splash_screen.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const OboiaApp());
}

class OboiaApp extends StatelessWidget {
  const OboiaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => CartProvider()),
        ChangeNotifierProvider(create: (_) => ShopProvider()),
      ],
      child: Consumer<AuthProvider>(
        builder: (context, auth, _) {
          // Keep cart bound to the current user
          context.read<CartProvider>().bindUser(
                auth.firebaseUser?.uid,
              );

          return MaterialApp.router(
            title: 'OBOIA',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.darkTheme,
            routerConfig: _router(auth),
          );
        },
      ),
    );
  }

  GoRouter _router(AuthProvider auth) {
    return GoRouter(
      initialLocation: '/splash',
      refreshListenable: auth,
      redirect: (context, state) {
        final loc = state.matchedLocation;

        // Splash handles its own timing
        if (loc == '/splash') return null;
        if (auth.loading) return null;

        final isAuthRoute = loc == '/welcome' ||
            loc == '/login' ||
            loc == '/signup';

        if (!auth.isSignedIn && !isAuthRoute) {
          return '/welcome';
        }
        if (auth.isSignedIn && isAuthRoute) {
          return auth.isCraftsman ? '/craftsman' : '/home';
        }
        return null;
      },
      routes: [
        GoRoute(
          path: '/splash',
          builder: (_, __) => const SplashScreen(),
        ),
        GoRoute(
          path: '/welcome',
          builder: (_, __) => const WelcomeScreen(),
        ),
        GoRoute(
          path: '/login',
          builder: (_, __) => const LoginScreen(),
        ),
        GoRoute(
          path: '/signup',
          builder: (_, __) => const SignupScreen(),
        ),
        GoRoute(
          path: '/home',
          builder: (_, __) => const HomeScreen(),
        ),
        GoRoute(
          path: '/shop/:shopId',
          builder: (_, state) => ShopScreen(
            shopId: state.pathParameters['shopId']!,
          ),
        ),
        GoRoute(
          path: '/ar',
          // Fixed: use ARScreen not ArScreen
          builder: (_, __) => const ARScreen(),
        ),
        GoRoute(
          path: '/cart',
          builder: (_, __) => const CartScreen(),
        ),
        GoRoute(
          path: '/order-confirm',
          builder: (_, __) => const OrderConfirmScreen(),
        ),
        GoRoute(
          path: '/orders',
          builder: (_, __) => const OrdersScreen(),
        ),
        GoRoute(
          path: '/orders/:id',
          builder: (_, state) => OrderDetailScreen(
            orderId: state.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/profile',
          builder: (_, __) => const ProfileScreen(),
        ),
        GoRoute(
          path: '/craftsman',
          builder: (_, __) => const CraftsmanHomeScreen(),
        ),
        GoRoute(
          path: '/craftsman/jobs',
          builder: (_, __) => const CraftsmanJobsScreen(),
        ),
        GoRoute(
          path: '/craftsman/bonus',
          builder: (_, __) => const CraftsmanBonusScreen(),
        ),
      ],
    );
  }
}