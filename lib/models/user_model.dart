import 'package:cloud_firestore/cloud_firestore.dart';

class AppUser {
  final String uid;
  final String name;
  final String email;
  final String role; // admin | seller | craftsman | customer
  final String? shopId;
  final String? photoUrl;
  final bool isBlocked;
  final List<String> savedShops;
  final DateTime createdAt;

  const AppUser({
    required this.uid,
    required this.name,
    required this.email,
    required this.role,
    this.shopId,
    this.photoUrl,
    this.isBlocked = false,
    this.savedShops = const [],
    required this.createdAt,
  });

  bool get isCraftsman => role == 'craftsman';
  bool get isCustomer => role == 'customer';
  bool get isAdmin => role == 'admin';

  factory AppUser.fromDoc(DocumentSnapshot doc) {
    final d = (doc.data() as Map<String, dynamic>? ?? {});
    return AppUser(
      uid: doc.id,
      name: (d['name'] ?? '') as String,
      email: (d['email'] ?? '') as String,
      role: (d['role'] ?? 'customer') as String,
      shopId: d['shopId'] as String?,
      photoUrl: d['photoUrl'] as String?,
      isBlocked: (d['isBlocked'] ?? false) as bool,
      savedShops: List<String>.from(d['savedShops'] ?? const []),
      createdAt: (d['createdAt'] is Timestamp)
          ? (d['createdAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'email': email,
        'role': role,
        'shopId': shopId,
        'photoUrl': photoUrl,
        'isBlocked': isBlocked,
        'savedShops': savedShops,
        'createdAt': Timestamp.fromDate(createdAt),
      };

  AppUser copyWith({
    String? name,
    String? photoUrl,
    List<String>? savedShops,
  }) {
    return AppUser(
      uid: uid,
      name: name ?? this.name,
      email: email,
      role: role,
      shopId: shopId,
      photoUrl: photoUrl ?? this.photoUrl,
      isBlocked: isBlocked,
      savedShops: savedShops ?? this.savedShops,
      createdAt: createdAt,
    );
  }
}
