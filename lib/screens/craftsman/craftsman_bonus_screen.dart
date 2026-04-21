import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/constants.dart';
import '../../utils/formatters.dart';

class CraftsmanBonusScreen extends StatelessWidget {
  const CraftsmanBonusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthProvider>().firebaseUser?.uid ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('My bonuses')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Confirmed
          StreamBuilder<double>(
            stream:
                FirestoreService.instance.confirmedBonusForCraftsman(uid),
            builder: (_, snap) => _bigCard(
              label: 'Confirmed — paid out',
              value: Fmt.uzs(snap.data ?? 0),
              subtitle: 'From closed receipts only.',
              highlight: true,
            ),
          ),
          const SizedBox(height: 12),
          // Pending
          StreamBuilder<double>(
            stream: FirestoreService.instance.pendingBonusForCraftsman(uid),
            builder: (_, snap) => _bigCard(
              label: 'Pending',
              value: Fmt.uzs(snap.data ?? 0),
              subtitle:
                  'Will be confirmed once the shop closes the receipt. Refunds reverse the bonus.',
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            'Payment history',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: FirestoreService.instance
                .paymentHistoryForCraftsman(uid),
            builder: (_, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child:
                        CircularProgressIndicator(color: AppColors.gold),
                  ),
                );
              }
              final sales = snap.data ?? const [];
              if (sales.isEmpty) {
                return _emptyHistory();
              }
              return Column(
                children:
                    sales.map((s) => _historyTile(s)).toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _bigCard({
    required String label,
    required String value,
    required String subtitle,
    bool highlight = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: highlight ? AppColors.gold.withOpacity(0.08) : AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlight ? AppColors.borderGold : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style:
                const TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: highlight ? AppColors.gold : AppColors.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style:
                const TextStyle(color: AppColors.textTertiary, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _emptyHistory() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: const Center(
        child: Text(
          'No payment records yet',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      ),
    );
  }

  Widget _historyTile(Map<String, dynamic> sale) {
    final status = (sale['status'] ?? K.saleOpen) as String;
    final bonus = ((sale['craftsmanBonus'] ?? 0) as num).toDouble();
    final total = ((sale['totalAmount'] ?? 0) as num).toDouble();
    final closedAt = sale['closedAt'];
    final date = closedAt is Timestamp ? closedAt.toDate() : null;

    Color color;
    String label;
    switch (status) {
      case K.saleClosed:
        color = AppColors.success;
        label = 'Paid';
        break;
      case K.saleRefunded:
        color = AppColors.error;
        label = 'Refunded';
        break;
      default:
        color = AppColors.warning;
        label = 'Open';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withOpacity(0.4)),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sale ${Fmt.uzs(total)}',
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (date != null)
                  Text(
                    Fmt.dateTime(date),
                    style: const TextStyle(
                      color: AppColors.textTertiary,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            Fmt.uzs(bonus),
            style: const TextStyle(
              color: AppColors.gold,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
