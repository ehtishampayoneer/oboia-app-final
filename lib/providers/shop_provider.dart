import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/shop_model.dart';
import '../models/wallpaper_model.dart';

class ShopProvider extends ChangeNotifier {
  // ── Current shop context ────────────────────────────────────────────────
  ShopModel? _currentShop;
  WallpaperModel? _initialWallpaper;

  // ── All shops list ──────────────────────────────────────────────────────
  List<ShopModel> _shops = [];
  bool _shopsLoading = false;
  String? _shopsError;

  // ── Wallpapers per shop cache ───────────────────────────────────────────
  final Map<String, List<WallpaperModel>> _wallpaperCache = {};
  final Map<String, StreamSubscription<QuerySnapshot>> _wallpaperSubs = {};

  // ── Getters ─────────────────────────────────────────────────────────────
  ShopModel? get currentShop => _currentShop;
  WallpaperModel? get initialWallpaper => _initialWallpaper;
  List<ShopModel> get shops => List.unmodifiable(_shops);
  bool get shopsLoading => _shopsLoading;
  String? get shopsError => _shopsError;

  // ── Set current shop context (called before opening AR) ─────────────────
  void setContext({
    required ShopModel shop,
    WallpaperModel? wallpaper,
  }) {
    _currentShop = shop;
    _initialWallpaper = wallpaper;
    notifyListeners();
  }

  void clearInitialWallpaper() {
    _initialWallpaper = null;
  }

  // ── Load all active shops (real-time) ───────────────────────────────────
  StreamSubscription<QuerySnapshot>? _shopsSub;

  void startListeningToShops() {
    _shopsLoading = true;
    notifyListeners();

    _shopsSub = FirebaseFirestore.instance
        .collection('shops')
        .where('isActive', isEqualTo: true)
        .snapshots()
        .listen(
      (snapshot) {
        _shops = snapshot.docs
            .map((doc) => ShopModel.fromDoc(doc))
            .toList();
        _shopsLoading = false;
        _shopsError = null;
        notifyListeners();
      },
      onError: (error) {
        _shopsError = error.toString();
        _shopsLoading = false;
        notifyListeners();
      },
    );
  }

  void stopListeningToShops() {
    _shopsSub?.cancel();
    _shopsSub = null;
  }

  // ── Get wallpapers for a specific shop ──────────────────────────────────
  List<WallpaperModel> wallpapersForShop(String shopId) {
    return _wallpaperCache[shopId] ?? [];
  }

  // ── Start real-time listener for shop wallpapers ────────────────────────
  void startListeningToWallpapers(String shopId) {
    if (_wallpaperSubs.containsKey(shopId)) return;

    _wallpaperSubs[shopId] = FirebaseFirestore.instance
        .collection('wallpapers')
        .where('shopId', isEqualTo: shopId)
        .where('isApproved', isEqualTo: true)
        .snapshots()
        .listen(
      (snapshot) {
        _wallpaperCache[shopId] = snapshot.docs
            .map((doc) => WallpaperModel.fromDoc(doc))
            .toList();
        notifyListeners();
      },
      onError: (error) {
        debugPrint('Wallpaper listener error for $shopId: $error');
      },
    );
  }

  // ── Stop wallpaper listener for a shop ──────────────────────────────────
  void stopListeningToWallpapers(String shopId) {
    _wallpaperSubs[shopId]?.cancel();
    _wallpaperSubs.remove(shopId);
    _wallpaperCache.remove(shopId);
  }

  // ── Get a single shop by id ─────────────────────────────────────────────
  ShopModel? shopById(String shopId) {
    try {
      return _shops.firstWhere((s) => s.id == shopId);
    } catch (_) {
      return null;
    }
  }

  // ── Cleanup ─────────────────────────────────────────────────────────────
  @override
  void dispose() {
    _shopsSub?.cancel();
    for (final sub in _wallpaperSubs.values) {
      sub.cancel();
    }
    _wallpaperSubs.clear();
    super.dispose();
  }
}