import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../models/shop_model.dart';
import '../../models/wallpaper_model.dart';
import '../../providers/shop_provider.dart';
import '../../services/firestore_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/loading_skeleton.dart';
import '../../widgets/wallpaper_card.dart';

class ShopScreen extends StatefulWidget {
  final String shopId;
  const ShopScreen({super.key, required this.shopId});

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  String? _category;
  String _query = '';
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<Shop?>(
        stream: FirestoreService.instance.shopStream(widget.shopId),
        builder: (context, shopSnap) {
          final shop = shopSnap.data;
          return CustomScrollView(
            slivers: [
              SliverAppBar(
                expandedHeight: 220,
                pinned: true,
                backgroundColor: AppColors.background,
                iconTheme: const IconThemeData(color: AppColors.textPrimary),
                flexibleSpace: FlexibleSpaceBar(
                  background: _banner(shop),
                  title: Text(
                    shop?.name ?? '',
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                    ),
                  ),
                  titlePadding:
                      const EdgeInsets.symmetric(horizontal: 48, vertical: 14),
                ),
              ),
              if ((shop?.description ?? '').isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                    child: Text(
                      shop!.description,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: AppColors.textPrimary),
                    onChanged: (v) =>
                        setState(() => _query = v.toLowerCase().trim()),
                    decoration: const InputDecoration(
                      hintText: 'Search wallpapers',
                      prefixIcon: Icon(Icons.search,
                          color: AppColors.textSecondary, size: 20),
                    ),
                  ),
                ),
              ),
              StreamBuilder<List<Wallpaper>>(
                stream: FirestoreService.instance
                    .wallpapersForShopStream(widget.shopId),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const SliverToBoxAdapter(child: _LoadingGrid());
                  }
                  if (snap.hasError) {
                    return SliverToBoxAdapter(
                      child: _msgBox(
                        icon: Icons.error_outline,
                        text: 'Could not load wallpapers.',
                      ),
                    );
                  }
                  final all = snap.data ?? const <Wallpaper>[];
                  final categories = <String>{
                    for (final w in all)
                      if (w.category.isNotEmpty) w.category
                  }.toList()
                    ..sort();

                  final filtered = all.where((w) {
                    if (_category != null && w.category != _category) {
                      return false;
                    }
                    if (_query.isEmpty) return true;
                    return w.name.toLowerCase().contains(_query) ||
                        w.brand.toLowerCase().contains(_query);
                  }).toList();

                  return SliverMainAxisGroup(slivers: [
                    if (categories.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _categoryChips(categories),
                      ),
                    if (filtered.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: _msgBox(
                          icon: Icons.inventory_2_outlined,
                          text: all.isEmpty
                              ? 'No wallpapers yet in this shop.'
                              : 'No results for this filter.',
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        sliver: SliverGrid(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.72,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) {
                              final w = filtered[i];
                              return WallpaperCard(
                                wallpaper: w,
                                onTap: () => _openAR(shop, w),
                              );
                            },
                            childCount: filtered.length,
                          ),
                        ),
                      ),
                  ]);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  void _openAR(Shop? shop, Wallpaper w) {
    if (shop == null) return;
    context.read<ShopProvider>().setContext(shop: shop, wallpaper: w);
    context.push('/ar');
  }

  Widget _banner(Shop? shop) {
    final url = shop?.bannerUrl ?? shop?.thumbnailUrl ?? '';
    return Stack(
      fit: StackFit.expand,
      children: [
        if (url.isNotEmpty)
          CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            errorWidget: (_, __, ___) => Container(color: AppColors.surface),
            placeholder: (_, __) => Container(color: AppColors.surface),
          )
        else
          Container(color: AppColors.surface),
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, AppColors.background],
            ),
          ),
        ),
      ],
    );
  }

  Widget _categoryChips(List<String> categories) {
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: categories.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            final active = _category == null;
            return _chip('All', active, () => setState(() => _category = null));
          }
          final cat = categories[i - 1];
          final active = _category == cat;
          return _chip(cat, active, () => setState(() => _category = cat));
        },
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: active ? AppColors.gold : AppColors.card,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: active ? AppColors.gold : AppColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.black : AppColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 12.5,
            ),
          ),
        ),
      ),
    );
  }

  Widget _msgBox({required IconData icon, required String text}) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        children: [
          Icon(icon, color: AppColors.textTertiary, size: 48),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _LoadingGrid extends StatelessWidget {
  const _LoadingGrid();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 6,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.72,
        ),
        itemBuilder: (_, __) => const WallpaperCardSkeleton(),
      ),
    );
  }
}
