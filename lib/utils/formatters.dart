import 'package:intl/intl.dart';

class Fmt {
  Fmt._();

  static final NumberFormat _uzs = NumberFormat.currency(
    locale: 'en_US',
    symbol: '',
    decimalDigits: 0,
  );

  static final NumberFormat _usd = NumberFormat.currency(
    locale: 'en_US',
    symbol: '\$',
    decimalDigits: 2,
  );

  /// Uzbek som amount — "1 250 000 UZS".
  static String uzs(num amount) {
    final formatted = _uzs.format(amount).trim().replaceAll(',', ' ');
    return '$formatted UZS';
  }

  /// USD amount — "\$123.45".
  static String usd(num amount) => _usd.format(amount);

  /// Two-decimal meter value — "2.45 m".
  static String meters(num v) => '${v.toStringAsFixed(2)} m';

  /// Two-decimal sqm value — "6.30 m²".
  static String sqm(num v) => '${v.toStringAsFixed(2)} m²';

  /// Short date — "19 Apr 2026".
  static String date(DateTime d) => DateFormat('d MMM yyyy').format(d);

  /// Compact date & time — "19 Apr, 14:32".
  static String dateTime(DateTime d) => DateFormat('d MMM, HH:mm').format(d);

  /// Short order code from a Firestore id — "A1B2C3".
  static String shortCode(String id) =>
      id.length >= 6 ? id.substring(0, 6).toUpperCase() : id.toUpperCase();
}
