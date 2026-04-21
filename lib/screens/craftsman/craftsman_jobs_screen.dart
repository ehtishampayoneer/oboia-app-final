import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/order_model.dart';
import '../../providers/auth_provider.dart';
import '../../services/firestore_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';
import '../../widgets/order_status_badge.dart';

class CraftsmanJobsScreen extends StatelessWidget {
  const CraftsmanJobsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = context.watch<AuthProvider>().firebaseUser?.uid ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('Assigned jobs')),
      body: StreamBuilder<List<AppOrder>>(
        stream: FirestoreService.instance.jobsForCraftsmanStream(uid),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
                child: CircularProgressIndicator(color: AppColors.gold));
          }
          final jobs = snap.data ?? const <AppOrder>[];
          if (jobs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.work_off_outlined,
                        color: AppColors.textTertiary, size: 56),
                    SizedBox(height: 14),
                    Text(
                      'No jobs assigned yet',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'The shop will assign installation jobs to you from the dashboard.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: jobs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final j = jobs[i];
              final firstItem = j.items.isEmpty ? null : j.items.first;
              return InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => context.push('/orders/${j.id}'),
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '#${Fmt.shortCode(j.id)}',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          OrderStatusBadge(status: j.status),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _line(Icons.person_outline_rounded, j.customerName),
                      if (j.customerPhone.isNotEmpty)
                        _line(Icons.phone_outlined, j.customerPhone),
                      if (j.customerAddress.isNotEmpty)
                        _line(Icons.location_on_outlined, j.customerAddress),
                      if (firstItem != null) ...[
                        const SizedBox(height: 6),
                        _line(Icons.wallpaper_rounded,
                            '${firstItem.wallpaperName} · ${firstItem.rollsNeeded} rolls'),
                      ],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _line(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
