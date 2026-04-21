// lib/services/cart_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/cart_model.dart';
import '../utils/constants.dart';

/// Cart is persisted in Firestore at carts/{userId} as a document with an
/// "items" array. Survives reinstalls and syncs across devices.
class CartService {
  CartService._();
  static final CartService instance = CartService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> _cartRef(String userId) =>
      _db.collection(K.carts).doc(userId);

  // ── Streams ──────────────────────────────────────────────────────────────

  /// Real-time stream of the user's cart, sorted newest-first.
  Stream<List<CartItem>> cartStream(String userId) {
    return _cartRef(userId).snapshots().map((snap) {
      if (!snap.exists) return <CartItem>[];
      final raw = (snap.data()?['items'] as List?) ?? const [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(CartItem.fromMap)
          .toList()
        ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    });
  }

  // ── One-shot reads ────────────────────────────────────────────────────────

  Future<List<CartItem>> currentCart(String userId) async {
    final snap = await _cartRef(userId).get();
    if (!snap.exists) return <CartItem>[];
    final raw = (snap.data()?['items'] as List?) ?? const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(CartItem.fromMap)
        .toList();
  }

  // ── Mutations ─────────────────────────────────────────────────────────────

  Future<void> addItem(String userId, CartItem item) async {
    await _cartRef(userId).set(
      {
        'userId': userId,
        'items': FieldValue.arrayUnion([item.toMap()]),
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<void> removeItem(String userId, String cartItemId) async {
    final current = await currentCart(userId);
    final remaining = current
        .where((c) => c.id != cartItemId)
        .map((e) => e.toMap())
        .toList();

    await _cartRef(userId).set(
      {
        'userId': userId,
        'items': remaining,
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<void> clear(String userId) async {
    await _cartRef(userId).set(
      {
        'userId': userId,
        'items': <Map<String, dynamic>>[],
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }
}