import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/cart_model.dart';
import '../../models/order_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/cart_provider.dart';
import '../../services/firestore_service.dart';
import '../../theme/app_colors.dart';
import '../../utils/formatters.dart';
import '../../widgets/custom_button.dart';
import '../../widgets/custom_text_field.dart';

class OrderConfirmScreen extends StatefulWidget {
  const OrderConfirmScreen({super.key});

  @override
  State<OrderConfirmScreen> createState() => _OrderConfirmScreenState();
}

class _OrderConfirmScreenState extends State<OrderConfirmScreen> {
  final _form = GlobalKey<FormState>();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  final _notes = TextEditingController();
  bool _placing = false;

  @override
  void dispose() {
    _address.dispose();
    _phone.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _placeOrder() async {
    if (!_form.currentState!.validate()) return;
    final auth = context.read<AuthProvider>();
    final cart = context.read<CartProvider>();
    final user = auth.firebaseUser;
    final profile = auth.appUser;
    if (user == null || profile == null) return;
    if (cart.items.isEmpty) return;

    setState(() => _placing = true);
    try {
      final byShop = cart.itemsByShop();
      for (final entry in byShop.entries) {
        final shopId = entry.key;
        final items = entry.value;
        final total = items.fold<double>(0, (a, b) => a + b.totalPrice);
        final shopName = items.first.shopName;

        await FirestoreService.instance.createOrder(
          customerId: user.uid,
          customerName: profile.name,
          customerPhone: _phone.text.trim(),
          customerAddress: _address.text.trim(),
          notes: _notes.text.trim(),
          shopId: shopId,
          shopName: shopName,
          items: items.map(_toOrderItem).toList(),
          totalAmount: total,
        );
      }
      await cart.clear();
      if (!mounted) return;
      _showSuccess();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not place order: $e')),
      );
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }

  OrderItem _toOrderItem(CartItem c) => OrderItem(
        wallpaperId: c.wallpaperId,
        wallpaperName: c.wallpaperName,
        wallpaperThumbnail: c.wallpaperThumbnail,
        wallWidth: c.wallWidth,
        wallHeight: c.wallHeight,
        sqm: c.sqm,
        rollsNeeded: c.rollsNeeded,
        pricePerRoll: c.pricePerRoll,
        totalPrice: c.totalPrice,
      );

  void _showSuccess() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.success.withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_rounded,
                  color: AppColors.success, size: 32),
            ),
            const SizedBox(height: 14),
            const Text(
              'Order placed!',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'The shop will contact you shortly to confirm.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ],
        ),
        actions: [
          CustomButton(
            label: 'View my orders',
            onPressed: () {
              Navigator.of(context).pop();
              context.go('/orders');
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Confirm order')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              // Summary
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Order summary',
                      style: TextStyle(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ...cart.items.map((it) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${it.wallpaperName} · ${it.rollsNeeded} rolls',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                              Text(
                                Fmt.uzs(it.totalPrice),
                                style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        )),
                    const Divider(color: AppColors.border, height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Total',
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          Fmt.uzs(cart.grandTotal),
                          style: const TextStyle(
                            color: AppColors.gold,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              CustomTextField(
                label: 'Delivery address',
                controller: _address,
                prefixIcon: Icons.location_on_outlined,
                maxLines: 2,
                validator: (v) => (v == null || v.trim().length < 5)
                    ? 'Please enter your address'
                    : null,
              ),
              const SizedBox(height: 14),
              CustomTextField(
                label: 'Phone number',
                controller: _phone,
                prefixIcon: Icons.phone_outlined,
                keyboardType: TextInputType.phone,
                validator: (v) => (v == null || v.trim().length < 7)
                    ? 'Enter a valid phone'
                    : null,
              ),
              const SizedBox(height: 14),
              CustomTextField(
                label: 'Notes for the shop (optional)',
                controller: _notes,
                prefixIcon: Icons.notes_rounded,
                maxLines: 3,
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 28),
              CustomButton(
                label: 'Confirm order',
                icon: Icons.check_rounded,
                loading: _placing,
                onPressed: cart.items.isEmpty ? null : _placeOrder,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
