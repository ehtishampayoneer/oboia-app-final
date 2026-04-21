import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/wallpaper_model.dart';
import '../theme/app_colors.dart';

/// Horizontal, grouped-by-shop thumbnail bar. Tapping a thumbnail
/// invokes [onPick] so the AR view can update the selected wall
/// instantly (no loading screen).
class WallpaperThumbnailBar extends StatelessWidget {
  final Map<String, List<Wallpaper>> wallpapersByShop;
  final Map<String, String> shopNames; // shopId -> shop display name
  final String? currentShopId;
  final String? selectedWallpaperId;
  final ValueChanged<Wallpaper> onPick;

  const WallpaperThumbnailBar({
    super.key,
    required this.wallpapersByShop,
    required this.shopNames,
    required this.currentShopId,
    required this.selectedWallpaperId,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    // Order: current shop first, then the rest by shop name.
    final keys = wallpapersByShop.keys.toList()
      ..sort((a, b) {
        if (a == currentShopId) return -1;
        if (b == currentShopId) return 1;
        return (shopNames[a] ?? '').compareTo(shopNames[b] ?? '');
      });

    return Container(
      height: 128,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.75),
        border: const Border(top: BorderSide(color: AppColors.borderGold)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        itemCount: keys.length,
        itemBuilder: (context, idx) {
          final shopId = keys[idx];
          final items = wallpapersByShop[shopId] ?? const <Wallpaper>[];
          if (items.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _ShopGroup(
              shopName: shopNames[shopId] ?? 'Shop',
              isCurrent: shopId == currentShopId,
              wallpapers: items,
              selectedWallpaperId: selectedWallpaperId,
              onPick: onPick,
            ),
          );
        },
      ),
    );
  }
}

class _ShopGroup extends StatelessWidget {
  final String shopName;
  final bool isCurrent;
  final List<Wallpaper> wallpapers;
  final String? selectedWallpaperId;
  final ValueChanged<Wallpaper> onPick;

  const _ShopGroup({
    required this.shopName,
    required this.isCurrent,
    required this.wallpapers,
    required this.selectedWallpaperId,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: isCurrent ? AppColors.gold : AppColors.textSecondary,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                shopName,
                style: TextStyle(
                  color: isCurrent ? AppColors.gold : AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
        Row(
          children: wallpapers.take(20).map((w) {
            final selected = w.id == selectedWallpaperId;
            return GestureDetector(
              onTap: () => onPick(w),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.only(right: 8),
                width: 72,
                height: 80,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected ? AppColors.gold : Colors.transparent,
                    width: selected ? 2 : 0,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: w.thumbnailUrl != null && w.thumbnailUrl!.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: w.thumbnailUrl!,
                          fit: BoxFit.cover,
                          placeholder: (_, __) =>
                              Container(color: AppColors.surface),
                          errorWidget: (_, __, ___) =>
                              Container(color: AppColors.surface),
                        )
                      : Container(
                          color: AppColors.surface,
                          child: const Icon(Icons.wallpaper,
                              color: AppColors.textTertiary),
                        ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
