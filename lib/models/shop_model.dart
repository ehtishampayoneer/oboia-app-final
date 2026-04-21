import 'package:cloud_firestore/cloud_firestore.dart';

class ShopModel {
  final String id;
  final String token;
  final String name;
  final String description;
  final String? thumbnailUrl;
  final String? bannerUrl;
  final bool isActive;
  final double exchangeRate;
  final String? ownerId;
  final int wallpaperCount;
  final DateTime createdAt;

  const ShopModel({
    required this.id,
    required this.token,
    required this.name,
    required this.description,
    this.thumbnailUrl,
    this.bannerUrl,
    required this.isActive,
    required this.exchangeRate,
    this.ownerId,
    this.wallpaperCount = 0,
    required this.createdAt,
  });

  factory ShopModel.fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map<String, dynamic>?) ?? {};
    return ShopModel(
      id: doc.id,
      token: (d['token'] ?? '') as String,
      name: (d['name'] ?? 'Unnamed shop') as String,
      description: (d['description'] ?? '') as String,
      thumbnailUrl: d['thumbnailUrl'] as String?,
      bannerUrl: d['bannerUrl'] as String?,
      isActive: (d['isActive'] ?? true) as bool,
      exchangeRate: ((d['exchangeRate'] ?? 12500) as num).toDouble(),
      ownerId: d['ownerId'] as String?,
      wallpaperCount: ((d['wallpaperCount'] ?? 0) as num).toInt(),
      createdAt: (d['createdAt'] is Timestamp)
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'token': token,
      'name': name,
      'description': description,
      'thumbnailUrl': thumbnailUrl,
      'bannerUrl': bannerUrl,
      'isActive': isActive,
      'exchangeRate': exchangeRate,
      'ownerId': ownerId,
      'wallpaperCount': wallpaperCount,
      'createdAt': createdAt,
    };
  }
}

// Backwards compatibility alias
typedef Shop = ShopModel;