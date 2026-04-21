/// Central constants so we never hard-code collection names or magic strings.
class K {
  K._();

  // Firestore collections
  static const String users = 'users';
  static const String shops = 'shops';
  static const String wallpapers = 'wallpapers';
  static const String orders = 'orders';
  static const String sales = 'sales';
  static const String customers = 'customers';
  static const String carts = 'carts';

  // User roles
  static const String roleAdmin = 'admin';
  static const String roleSeller = 'seller';
  static const String roleCraftsman = 'craftsman';
  static const String roleCustomer = 'customer';

  // Order statuses
  static const String statusPending = 'pending';
  static const String statusNegotiating = 'negotiating';
  static const String statusReady = 'ready';
  static const String statusClosed = 'closed';
  static const String statusCancelled = 'cancelled';

  // Sale statuses (bonuses only on closed)
  static const String saleOpen = 'open';
  static const String saleClosed = 'closed';
  static const String saleRefunded = 'refunded';

  // Supported languages
  static const List<Locale> supportedLocales = [
    Locale('en'),
    Locale('uz'),
  ];
}

// Avoid a dart:ui import just for Locale above.
class Locale {
  final String code;
  const Locale(this.code);
}
