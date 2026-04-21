import 'package:cloud_firestore/cloud_firestore.dart';

class OrderItem {
  final String wallpaperId;
  final String wallpaperName;
  final String? wallpaperThumbnail;
  final double wallWidth;
  final double wallHeight;
  final double sqm;
  final int rollsNeeded;
  final double pricePerRoll;
  final double totalPrice;

  const OrderItem({
    required this.wallpaperId,
    required this.wallpaperName,
    this.wallpaperThumbnail,
    required this.wallWidth,
    required this.wallHeight,
    required this.sqm,
    required this.rollsNeeded,
    required this.pricePerRoll,
    required this.totalPrice,
  });

  factory OrderItem.fromMap(Map<String, dynamic> m) => OrderItem(
        wallpaperId: (m['wallpaperId'] ?? '') as String,
        wallpaperName: (m['wallpaperName'] ?? '') as String,
        wallpaperThumbnail: m['wallpaperThumbnail'] as String?,
        wallWidth: ((m['wallWidth'] ?? 0) as num).toDouble(),
        wallHeight: ((m['wallHeight'] ?? 0) as num).toDouble(),
        sqm: ((m['sqm'] ?? 0) as num).toDouble(),
        rollsNeeded: ((m['rollsNeeded'] ?? 0) as num).toInt(),
        pricePerRoll: ((m['pricePerRoll'] ?? 0) as num).toDouble(),
        totalPrice: ((m['totalPrice'] ?? 0) as num).toDouble(),
      );

  Map<String, dynamic> toMap() => {
        'wallpaperId': wallpaperId,
        'wallpaperName': wallpaperName,
        'wallpaperThumbnail': wallpaperThumbnail,
        'wallWidth': wallWidth,
        'wallHeight': wallHeight,
        'sqm': sqm,
        'rollsNeeded': rollsNeeded,
        'pricePerRoll': pricePerRoll,
        'totalPrice': totalPrice,
      };
}

class AppOrder {
  final String id;
  final String customerId;
  final String customerName;
  final String customerPhone;
  final String customerAddress;
  final String notes;
  final String shopId;
  final String shopName;
  final List<OrderItem> items;
  final double totalAmount;
  final String status; // pending | negotiating | ready | closed | cancelled
  final String? craftsmanId;
  final DateTime createdAt;

  const AppOrder({
    required this.id,
    required this.customerId,
    required this.customerName,
    required this.customerPhone,
    required this.customerAddress,
    required this.notes,
    required this.shopId,
    required this.shopName,
    required this.items,
    required this.totalAmount,
    required this.status,
    this.craftsmanId,
    required this.createdAt,
  });

  factory AppOrder.fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map<String, dynamic>? ?? {});
    final rawItems = (d['items'] as List?) ?? const [];
    return AppOrder(
      id: doc.id,
      customerId: (d['customerId'] ?? '') as String,
      customerName: (d['customerName'] ?? '') as String,
      customerPhone: (d['customerPhone'] ?? '') as String,
      customerAddress: (d['customerAddress'] ?? '') as String,
      notes: (d['notes'] ?? '') as String,
      shopId: (d['shopId'] ?? '') as String,
      shopName: (d['shopName'] ?? '') as String,
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(OrderItem.fromMap)
          .toList(),
      totalAmount: ((d['totalAmount'] ?? 0) as num).toDouble(),
      status: (d['status'] ?? 'pending') as String,
      craftsmanId: d['craftsmanId'] as String?,
      createdAt: (d['createdAt'] is Timestamp)
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }
}
