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
    String _clean(String? url) => url?.trim().replaceAll(RegExp(r'^"|"$'), '') ?? '';
    return PbrMaps(
      albedoUrl: _clean(m['albedoUrl'] as String?),
      normalUrl: _clean(m['normalUrl'] as String?),
      roughnessUrl: _clean(m['roughnessUrl'] as String?),
      aoUrl: _clean(m['aoUrl'] as String?),
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
  final double price;
  final double pricePerSqm;
  final double rollWidth;
  final double rollLength;
  final int stock;
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

  bool get inStock => stock > 0;
  double get pricePerRoll => price;
  String get arTextureUrl =>
      pbr.albedoUrl.isNotEmpty ? pbr.albedoUrl : (thumbnailUrl ?? '');

  double sqmForWall(double wallWidth, double wallHeight) =>
      wallWidth * wallHeight;

  int rollsNeeded(double wallWidth, double wallHeight) {
    final sqm = sqmForWall(wallWidth, wallHeight);
    final perRoll = rollWidth * rollLength;
    if (perRoll <= 0) return 0;
    return (sqm / perRoll).ceil();
  }

  double totalPriceForWall(double wallWidth, double wallHeight) =>
      rollsNeeded(wallWidth, wallHeight) * price;

  static String _cleanUrl(String? url) =>
      url?.trim().replaceAll(RegExp(r'^"|"$'), '') ?? '';

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
      thumbnailUrl: _cleanUrl(d['thumbnailUrl'] as String?),
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
      thumbnailUrl: _cleanUrl(d['thumbnailUrl'] as String?),
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

typedef Wallpaper = WallpaperModel;
