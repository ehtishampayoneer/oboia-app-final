import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../models/user_model.dart';

/// Handles all authentication + provisioning of Firestore user docs.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final GoogleSignIn _google = GoogleSignIn();

  User? get currentFirebaseUser => _auth.currentUser;

  /// Live stream of Firebase auth state.
  Stream<User?> authStateChanges() => _auth.authStateChanges();

  /// Sign in with Google. Creates a Firestore user doc on first login.
  Future<User?> signInWithGoogle() async {
    final account = await _google.signIn();
    if (account == null) return null; // user cancelled
    final auth = await account.authentication;
    final credential = GoogleAuthProvider.credential(
      idToken: auth.idToken,
      accessToken: auth.accessToken,
    );
    final result = await _auth.signInWithCredential(credential);
    if (result.user != null) {
      await _ensureUserDoc(
        uid: result.user!.uid,
        name: result.user!.displayName ?? 'Customer',
        email: result.user!.email ?? '',
        photoUrl: result.user!.photoURL,
      );
    }
    return result.user;
  }

  /// Email + password sign up.
  Future<User?> signUpWithEmail({
    required String name,
    required String email,
    required String password,
  }) async {
    final result = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await result.user?.updateDisplayName(name);
    if (result.user != null) {
      await _ensureUserDoc(
        uid: result.user!.uid,
        name: name,
        email: email.trim(),
      );
    }
    return result.user;
  }

  /// Email + password sign in.
  Future<User?> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final result = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    return result.user;
  }

  Future<void> sendPasswordReset(String email) =>
      _auth.sendPasswordResetEmail(email: email.trim());

  Future<void> signOut() async {
    await _google.signOut().catchError((_) {});
    await _auth.signOut();
  }

  /// Ensure a Firestore users/{uid} doc exists. Never overwrites a non-customer
  /// role (protects craftsmen, admins, sellers created by the dashboard).
  Future<void> _ensureUserDoc({
    required String uid,
    required String name,
    required String email,
    String? photoUrl,
  }) async {
    final ref = _db.collection('users').doc(uid);
    final snap = await ref.get();
    if (!snap.exists) {
      await ref.set({
        'name': name,
        'email': email,
        'role': 'customer',
        'photoUrl': photoUrl,
        'isBlocked': false,
        'savedShops': <String>[],
        'createdAt': FieldValue.serverTimestamp(),
      });
    } else {
      // Only fill in missing fields — never downgrade a role set by dashboard.
      final data = snap.data() ?? {};
      final updates = <String, dynamic>{};
      if ((data['name'] ?? '').toString().isEmpty && name.isNotEmpty) {
        updates['name'] = name;
      }
      if ((data['email'] ?? '').toString().isEmpty && email.isNotEmpty) {
        updates['email'] = email;
      }
      if ((data['photoUrl'] == null) && (photoUrl != null)) {
        updates['photoUrl'] = photoUrl;
      }
      if (updates.isNotEmpty) await ref.update(updates);
    }
  }

  /// Live stream of the AppUser profile.
  Stream<AppUser?> userDocStream(String uid) {
    return _db.collection('users').doc(uid).snapshots().map((snap) {
      if (!snap.exists) return null;
      return AppUser.fromDoc(snap);
    });
  }
}
