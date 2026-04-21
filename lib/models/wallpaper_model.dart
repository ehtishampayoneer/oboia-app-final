import 'package:cloud_firestore/cloud_firestore.dart';

class PbrMaps {
  final String albedoUrl;
  final String normalUrl;
  final String roughnessUrl;
  final String aoUrl;

  const PbrMaps({
    this.albedoUrl = '',
    this.normalUrl = '',
    this.roughnessUrl = '',
    this.aoUrl = '',
  });

  factory PbrMaps.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const PbrMaps();
    return PbrMaps(
      albedoUrl: (m['albedoUrl'] as String?) ?? '',
      normalUrl: (m['normalUrl'] as String?) ?? '',
      roughnessUrl: (m['roughnessUrl'] as String?) ?? '',
      aoUrl: (m['aoUrl'] as String?) ?? '',
    );
  }

  bool get hasAlbedo => albedoUrl.isNotEmpty;
  bool get hasNormal => normalUrl.isNotEmpty;
  bool get hasRoughness => roughnessUrl.isNotEmpty;
  bool get hasAo => aoUrl.isNotEmpty;
  bool get hasFullPbr => hasAlbedo && hasNormal && hasRoughness && hasAo;
}

class WallpaperModel {
  final String id;
  final String name;
  final String description;
  final String category;
  final String brand;
  final double price;        // per roll, UZS
  final double pricePerSqm;  // UZS
  final double rollWidth;    // meters
  final double rollLength;   // meters
  final int stock;           // rolls available
  final String shopId;
  final bool isApproved;
  final String? thumbnailUrl;
  final PbrMaps pbr;
  final String? processingStatus;
  final DateTime createdAt;

  const WallpaperModel({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.brand,
    required this.price,
    required this.pricePerSqm,
    required this.rollWidth,
    required this.rollLength,
    required this.stock,
    required this.shopId,
    required this.isApproved,
    this.thumbnailUrl,
    required this.pbr,
    this.processingStatus,
    required this.createdAt,
  });

  // ── Convenience getters ─────────────────────────────────────────────────

  bool get inStock => stock > 0;

  /// Price per roll (alias so ar_service can use pricePerRoll)
  double get pricePerRoll => price;

  /// Best available URL to paint on the wall in AR.
  String get arTextureUrl =>
      pbr.albedoUrl.isNotEmpty ? pbr.albedoUrl : (thumbnailUrl ?? '');

  // ── Calculations ────────────────────────────────────────────────────────

  /// sqm needed for a wall
  double sqmForWall(double wallWidth, double wallHeight) {
    return wallWidth * wallHeight;
  }

  /// Rolls needed - ALWAYS round UP
  int rollsNeeded(double wallWidth, double wallHeight) {
    final sqm = sqmForWall(wallWidth, wallHeight);
    final perRoll = rollWidth * rollLength;
    if (perRoll <= 0) return 0;
    return (sqm / perRoll).ceil();
  }

  /// Total price for a wall
  double totalPriceForWall(double wallWidth, double wallHeight) {
    return rollsNeeded(wallWidth, wallHeight) * price;
  }

  // ── Firestore ───────────────────────────────────────────────────────────

  factory WallpaperModel.fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map<String, dynamic>?) ?? {};
    return WallpaperModel(
      id: doc.id,
      name: (d['name'] ?? 'Unnamed') as String,
      description: (d['description'] ?? '') as String,
      category: (d['category'] ?? '') as String,
      brand: (d['brand'] ?? '') as String,
      price: ((d['price'] ?? 0) as num).toDouble(),
      pricePerSqm: ((d['pricePerSqm'] ?? 0) as num).toDouble(),
      rollWidth: ((d['rollWidth'] ?? 0.53) as num).toDouble(),
      rollLength: ((d['rollLength'] ?? 10) as num).toDouble(),
      stock: ((d['stock'] ?? 0) as num).toInt(),
      shopId: (d['shopId'] ?? '') as String,
      isApproved: (d['isApproved'] ?? false) as bool,
      thumbnailUrl: d['thumbnailUrl'] as String?,
      pbr: PbrMaps.fromMap(d['pbr'] as Map<String, dynamic>?),
      processingStatus: d['processingStatus'] as String?,
      createdAt: (d['createdAt'] is Timestamp)
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  factory WallpaperModel.fromMap(Map<String, dynamic> d, String id) {
    return WallpaperModel(
      id: id,
      name: (d['name'] ?? 'Unnamed') as String,
      description: (d['description'] ?? '') as String,
      category: (d['category'] ?? '') as String,
      brand: (d['brand'] ?? '') as String,
      price: ((d['price'] ?? 0) as num).toDouble(),
      pricePerSqm: ((d['pricePerSqm'] ?? 0) as num).toDouble(),
      rollWidth: ((d['rollWidth'] ?? 0.53) as num).toDouble(),
      rollLength: ((d['rollLength'] ?? 10) as num).toDouble(),
      stock: ((d['stock'] ?? 0) as num).toInt(),
      shopId: (d['shopId'] ?? '') as String,
      isApproved: (d['isApproved'] ?? false) as bool,
      thumbnailUrl: d['thumbnailUrl'] as String?,
      pbr: PbrMaps.fromMap(d['pbr'] as Map<String, dynamic>?),
      processingStatus: d['processingStatus'] as String?,
      createdAt: (d['createdAt'] is Timestamp)
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'category': category,
      'brand': brand,
      'price': price,
      'pricePerSqm': pricePerSqm,
      'rollWidth': rollWidth,
      'rollLength': rollLength,
      'stock': stock,
      'shopId': shopId,
      'isApproved': isApproved,
      'thumbnailUrl': thumbnailUrl,
      'pbr': {
        'albedoUrl': pbr.albedoUrl,
        'normalUrl': pbr.normalUrl,
        'roughnessUrl': pbr.roughnessUrl,
        'aoUrl': pbr.aoUrl,
      },
      'processingStatus': processingStatus,
      'createdAt': createdAt,
    };
  }
}

// ── Backwards compatibility alias ───────────────────────────────────────────
// In case any file still uses "Wallpaper" instead of "WallpaperModel"
typedef Wallpaper = WallpaperModel;