// lib/models/cart_model.dart

import 'package:cloud_firestore/cloud_firestore.dart';

class CartItem {
  final String id;
  final String wallpaperId;
  final String wallpaperName;
  final String? wallpaperThumbnail;
  final String shopId;
  final String shopName;
  final double wallWidth;
  final double wallHeight;
  final double sqm;
  final int rollsNeeded;
  final double pricePerRoll;
  final double totalPrice;
  final DateTime addedAt;

  CartItem({
    required this.id,
    required this.wallpaperId,
    required this.wallpaperName,
    this.wallpaperThumbnail,
    required this.shopId,
    required this.shopName,
    required this.wallWidth,
    required this.wallHeight,
    required this.sqm,
    required this.rollsNeeded,
    required this.pricePerRoll,
    required this.totalPrice,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  factory CartItem.fromMap(Map<String, dynamic> m) => CartItem(
        id: (m['id'] ?? '') as String,
        wallpaperId: (m['wallpaperId'] ?? '') as String,
        wallpaperName: (m['wallpaperName'] ?? '') as String,
        wallpaperThumbnail: m['wallpaperThumbnail'] as String?,
        shopId: (m['shopId'] ?? '') as String,
        shopName: (m['shopName'] ?? '') as String,
        wallWidth: ((m['wallWidth'] ?? 0) as num).toDouble(),
        wallHeight: ((m['wallHeight'] ?? 0) as num).toDouble(),
        sqm: ((m['sqm'] ?? 0) as num).toDouble(),
        rollsNeeded: ((m['rollsNeeded'] ?? 0) as num).toInt(),
        pricePerRoll: ((m['pricePerRoll'] ?? 0) as num).toDouble(),
        totalPrice: ((m['totalPrice'] ?? 0) as num).toDouble(),
        addedAt: (m['addedAt'] is Timestamp)
            ? (m['addedAt'] as Timestamp).toDate()
            : DateTime.now(),
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'wallpaperId': wallpaperId,
        'wallpaperName': wallpaperName,
        'wallpaperThumbnail': wallpaperThumbnail,
        'shopId': shopId,
        'shopName': shopName,
        'wallWidth': wallWidth,
        'wallHeight': wallHeight,
        'sqm': sqm,
        'rollsNeeded': rollsNeeded,
        'pricePerRoll': pricePerRoll,
        'totalPrice': totalPrice,
        'addedAt': Timestamp.fromDate(addedAt),
      };
}