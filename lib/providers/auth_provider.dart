import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/user_model.dart';
import '../services/auth_service.dart';

/// Holds the currently authenticated Firebase user + AppUser profile and
/// keeps both live-synced with Firestore.
class AuthProvider extends ChangeNotifier {
  User? _firebaseUser;
  AppUser? _appUser;
  bool _loading = true;

  StreamSubscription<User?>? _authSub;
  StreamSubscription<AppUser?>? _userDocSub;

  AuthProvider() {
    _listen();
  }

  User? get firebaseUser => _firebaseUser;
  AppUser? get appUser => _appUser;
  bool get loading => _loading;
  bool get isSignedIn => _firebaseUser != null;
  bool get isCraftsman => _appUser?.isCraftsman ?? false;

  void _listen() {
    _authSub = AuthService.instance.authStateChanges().listen((user) async {
      _firebaseUser = user;
      _userDocSub?.cancel();
      if (user == null) {
        _appUser = null;
        _loading = false;
        notifyListeners();
        return;
      }
      _userDocSub = AuthService.instance.userDocStream(user.uid).listen((u) {
        _appUser = u;
        _loading = false;
        notifyListeners();
      });
    });
  }

  Future<void> signOut() async {
    await AuthService.instance.signOut();
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _userDocSub?.cancel();
    super.dispose();
  }
}
