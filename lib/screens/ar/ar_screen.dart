// lib/screens/ar/ar_screen.dart

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/wallpaper_model.dart';
import '../../models/shop_model.dart';
import '../../providers/cart_provider.dart';
import '../../providers/shop_provider.dart';
import '../../services/ar_service.dart';
import '../../services/texture_cache_service.dart';
import '../../theme/app_theme.dart';

class ARScreen extends StatefulWidget {
  /// Optional wallpaper to open the screen with.
  /// If null, user must tap a wallpaper from bottom bar first.
  final WallpaperModel? initialWallpaper;

  /// Optional shop context.
  /// If null, uses currentShop from ShopProvider.
  final ShopModel? initialShop;

  const ARScreen({
    super.key,
    this.initialWallpaper,
    this.initialShop,
  });

  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen>
    with SingleTickerProviderStateMixin {
  final ARService _ar = ARService.instance;
  final TextureCacheService _cache = TextureCacheService.instance;

  // Wall state observed from native events
  final Map<int, WallMeasurements> _walls = {};
  int? _selectedWallIndex;

  // Which wallpaper is active on each wall index
  final Map<int, WallpaperModel> _wallpaperByWall = {};

  // Pending wallpaper — tapped in bar but not yet placed
  WallpaperModel? _pending;

  // Current shop (resolved from widget or provider)
  ShopModel? _currentShop;

  StreamSubscription<AREvent>? _sub;

  // Scanning pulse animation
  late final AnimationController _scanCtrl;

  // Preload progress
  double _preloadProgress = 0.0;
  bool _preloadDone = false;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _pending = widget.initialWallpaper;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolve shop from widget param or provider
    _currentShop = widget.initialShop ??
        context.read<ShopProvider>().currentShop;
    // Boot only once
    if (_sub == null) {
      _boot();
    }
  }

  Future<void> _boot() async {
    // Subscribe before init so we don't miss early events
    _sub = _ar.events.listen(_onAREvent);
    await _ar.initAR();

    // Preload textures for all wallpapers from current shop
    if (_currentShop == null) {
      setState(() => _preloadDone = true);
      return;
    }

    final shopProvider = context.read<ShopProvider>();
    final wallpapers = shopProvider.wallpapersForShop(_currentShop!.id);

    // Build list of all texture URLs
    final urls = <String>[];
    for (final w in wallpapers) {
      if (w.pbr.albedoUrl.isNotEmpty) urls.add(w.pbr.albedoUrl);
      if (w.pbr.normalUrl.isNotEmpty) urls.add(w.pbr.normalUrl);
      if (w.pbr.roughnessUrl.isNotEmpty) urls.add(w.pbr.roughnessUrl);
      if (w.pbr.aoUrl.isNotEmpty) urls.add(w.pbr.aoUrl);
    }

    if (!mounted) return;

    unawaited(_cache.preloadShopTextures(
      textureUrls: urls,
      onProgress: (p) {
        if (!mounted) return;
        setState(() {
          _preloadProgress = p;
          _preloadDone = p >= 1.0;
        });
      },
    ));
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _sub?.cancel();
    _ar.disposeAR();
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
    super.dispose();
  }

  // ── Native event handling ───────────────────────────────────────────────

  Future<void> _onAREvent(AREvent e) async {
    switch (e.type) {
      case 'wallDetected':
        final idx = e.wallIndex;
        if (idx == null || e.width == null || e.height == null) return;
        setState(() {
          _walls[idx] = WallMeasurements(
            wallIndex: idx,
            width: e.width!,
            height: e.height!,
            sqm: e.sqm ?? (e.width! * e.height!),
          );
          _selectedWallIndex ??= idx;
        });
        // Auto-place the pending wallpaper on first detected wall
        if (_pending != null && _wallpaperByWall[idx] == null) {
          await _placeOn(idx, _pending!);
        }
        break;

      case 'wallUpdated':
        final idx = e.wallIndex;
        if (idx == null || e.width == null || e.height == null) return;
        setState(() {
          _walls[idx] = WallMeasurements(
            wallIndex: idx,
            width: e.width!,
            height: e.height!,
            sqm: e.sqm ?? (e.width! * e.height!),
          );
        });
        break;

      case 'wallSelected':
        final idx = e.wallIndex;
        if (idx == null) return;
        setState(() => _selectedWallIndex = idx);
        break;

      case 'wallpaperPlaced':
        break;

      case 'error':
        final msg = e.errorMessage ?? 'AR error';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(msg),
              backgroundColor: Colors.red.shade900,
            ),
          );
        }
        break;
    }
  }

  Future<void> _placeOn(int wallIndex, WallpaperModel wallpaper) async {
    try {
      final alreadyPlaced = _wallpaperByWall[wallIndex] != null;
      if (alreadyPlaced) {
        await _ar.switchWallpaper(
          wallpaper: wallpaper,
          wallIndex: wallIndex,
          pricePerRoll: wallpaper.pricePerRoll,
        );
      } else {
        await _ar.placeWallpaper(
          wallpaper: wallpaper,
          wallIndex: wallIndex,
          pricePerRoll: wallpaper.pricePerRoll,
        );
      }
      setState(() {
        _wallpaperByWall[wallIndex] = wallpaper;
        _pending = null;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message ?? 'Failed to place wallpaper'),
          backgroundColor: Colors.red.shade900,
        ),
      );
    }
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildNativeARView(),
          if (_walls.isEmpty) _buildScanningOverlay(),
          _buildTopBar(),
          if (_walls.length > 1) _buildWallSelector(),
          if (_selectedWallIndex != null && _walls.isNotEmpty)
            _buildMeasurementsCard(),
          _buildBottomBar(),
          if (!_preloadDone) _buildPreloadChip(),
        ],
      ),
    );
  }

  // Layer 1 ───────────────────────────────────────────────────────────────

  Widget _buildNativeARView() {
    const viewType = 'com.oboia/ar_view';
    const Map<String, dynamic> creationParams = <String, dynamic>{};
    if (Platform.isIOS) {
      return UiKitView(
        viewType: viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    if (Platform.isAndroid) {
      return AndroidView(
        viewType: viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: Text(
          'AR is only supported on iOS and Android',
          style: TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  // Layer 2 ───────────────────────────────────────────────────────────────

  Widget _buildScanningOverlay() {
    return IgnorePointer(
      child: Center(
        child: AnimatedBuilder(
          animation: _scanCtrl,
          builder: (_, __) {
            final t = _scanCtrl.value;
            return Opacity(
              opacity: 0.7 + 0.3 * t,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _DashedRectangle(
                    size: Size(260 + 20 * t, 360 + 20 * t),
                    color: AppTheme.gold,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Point the camera at a wall',
                    style:
                        Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Colors.white,
                              shadows: const [
                                Shadow(
                                  blurRadius: 8,
                                  color: Colors.black87,
                                ),
                              ],
                            ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // Layer 4 ───────────────────────────────────────────────────────────────

  Widget _buildMeasurementsCard() {
    final m = _walls[_selectedWallIndex];
    if (m == null) return const SizedBox.shrink();

    final wallpaper = _wallpaperByWall[_selectedWallIndex] ??
        widget.initialWallpaper;
    if (wallpaper == null) return const SizedBox.shrink();

    final rolls = m.rollsNeeded(
      rollWidth: wallpaper.rollWidth,
      rollLength: wallpaper.rollLength,
    );
    final total = rolls * wallpaper.pricePerRoll;

    return Positioned(
      top: MediaQuery.of(context).padding.top + 12,
      left: 16,
      right: 16,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppTheme.gold.withValues(alpha: 0.5),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row(
                  Icons.straighten,
                  '${m.width.toStringAsFixed(2)} m × '
                  '${m.height.toStringAsFixed(2)} m',
                ),
                const SizedBox(height: 4),
                _row(
                  Icons.crop_square,
                  '${m.sqm.toStringAsFixed(2)} sqm',
                ),
                const SizedBox(height: 4),
                _row(Icons.view_module, '$rolls rolls needed'),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(
                      Icons.local_offer,
                      size: 16,
                      color: AppTheme.gold,
                    ),
                    const SizedBox(width: 8),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Text(
                        '${_formatUZS(total)} UZS',
                        key: ValueKey(total),
                        style: const TextStyle(
                          color: AppTheme.gold,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(IconData icon, String text) => Row(
        children: [
          Icon(icon, size: 16, color: Colors.white70),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
              ),
            ),
          ),
        ],
      );

  String _formatUZS(double v) {
    final s = v.round().toString();
    final b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
      b.write(s[i]);
    }
    return b.toString();
  }

  // Layer 5 ───────────────────────────────────────────────────────────────

  Widget _buildWallSelector() {
    final indices = _walls.keys.toList()..sort();
    return Positioned(
      left: 12,
      top: MediaQuery.of(context).size.height / 2 - 80,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final i in indices)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: GestureDetector(
                onTap: () => _ar.selectWall(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _selectedWallIndex == i
                        ? AppTheme.gold
                        : Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppTheme.gold.withValues(
                        alpha: _selectedWallIndex == i ? 1 : 0.3,
                      ),
                    ),
                  ),
                  child: Text(
                    'Wall ${i + 1}',
                    style: TextStyle(
                      color: _selectedWallIndex == i
                          ? Colors.black
                          : Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Layer 6 + top chrome ──────────────────────────────────────────────────

  Widget _buildTopBar() {
    final cart = context.watch<CartProvider>();
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 4,
      right: 4,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: const CircleAvatar(
              backgroundColor: Colors.black54,
              child: Icon(Icons.arrow_back, color: Colors.white),
            ),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          _AddToCartButton(
            count: cart.totalItems,
            onTap: _addCurrentToCart,
          ),
        ],
      ),
    );
  }

  Future<void> _addCurrentToCart() async {
    final sel = _selectedWallIndex;
    if (sel == null || _walls[sel] == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Point the camera at a wall first'),
        ),
      );
      return;
    }

    final m = _walls[sel]!;
    final wp = _wallpaperByWall[sel] ?? widget.initialWallpaper;

    if (wp == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a wallpaper first'),
        ),
      );
      return;
    }

    final shop = _currentShop;

    await context.read<CartProvider>().addWallpaperToCart(
          wallpaper: wp,
          shopId: shop?.id ?? wp.shopId,
          shopName: shop?.name ?? 'Unknown Shop',
          wallWidth: m.width,
          wallHeight: m.height,
        );

    if (!mounted) return;
    final rolls = m.rollsNeeded(
      rollWidth: wp.rollWidth,
      rollLength: wp.rollLength,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Added $rolls rolls of ${wp.name} to cart'),
        backgroundColor: Colors.black87,
      ),
    );
  }

  // Layer 7 ───────────────────────────────────────────────────────────────

  Widget _buildBottomBar() {
    final shopProvider = context.watch<ShopProvider>();
    final shop = _currentShop;
    final currentShopWallpapers = shop != null
        ? shopProvider.wallpapersForShop(shop.id)
        : <WallpaperModel>[];
    final otherShops = shopProvider.shops
        .where((s) => s.id != shop?.id)
        .toList();

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        height: 168,
        color: const Color(0xF00A0A0A),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (shop != null)
                _shopSection(
                  title: shop.name,
                  titleColor: AppTheme.gold,
                  wallpapers: currentShopWallpapers,
                ),
              for (final s in otherShops) ...[
                const _DividerBar(),
                _shopSection(
                  title: s.name,
                  titleColor: Colors.white60,
                  wallpapers: shopProvider.wallpapersForShop(s.id),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _shopSection({
    required String title,
    required Color titleColor,
    required List<WallpaperModel> wallpapers,
  }) {
    final activeId = _selectedWallIndex != null
        ? _wallpaperByWall[_selectedWallIndex]?.id
        : _pending?.id;

    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: titleColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final wp in wallpapers) ...[
                _Thumbnail(
                  wallpaper: wp,
                  isActive: wp.id == activeId,
                  onTap: () => _onThumbnailTapped(wp),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _onThumbnailTapped(WallpaperModel wp) async {
    final sel = _selectedWallIndex;
    if (sel != null && _walls.containsKey(sel)) {
      await _placeOn(sel, wp);
    } else {
      setState(() => _pending = wp);
    }
  }

  Widget _buildPreloadChip() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 60,
      left: 16,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppTheme.gold.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: _preloadProgress == 0
                        ? null
                        : _preloadProgress,
                    color: AppTheme.gold,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Preparing textures… '
                  '${(_preloadProgress * 100).round()}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Helper widgets ──────────────────────────────────────────────────────────

class _AddToCartButton extends StatefulWidget {
  final int count;
  final VoidCallback onTap;
  const _AddToCartButton({
    required this.count,
    required this.onTap,
  });

  @override
  State<_AddToCartButton> createState() => _AddToCartButtonState();
}

class _AddToCartButtonState extends State<_AddToCartButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    lowerBound: 0.9,
    upperBound: 1.1,
    value: 1.0,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _bounce() {
    _c
      ..value = 0.9
      ..forward().then((_) => _c.reverse(from: 1.1));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        _bounce();
        widget.onTap();
      },
      child: ScaleTransition(
        scale: _c,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const CircleAvatar(
              radius: 22,
              backgroundColor: AppTheme.gold,
              child: Icon(
                Icons.shopping_cart,
                color: Colors.black,
                size: 20,
              ),
            ),
            if (widget.count > 0)
              Positioned(
                right: -4,
                top: -4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 20,
                    minHeight: 20,
                  ),
                  child: Text(
                    '${widget.count}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final WallpaperModel wallpaper;
  final bool isActive;
  final VoidCallback onTap;

  const _Thumbnail({
    required this.wallpaper,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final thumbUrl = wallpaper.thumbnailUrl ?? '';
    return Tooltip(
      message: wallpaper.name,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive
                  ? AppTheme.gold
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: thumbUrl.isEmpty
                ? Container(color: Colors.black26)
                : CachedNetworkImage(
                    imageUrl: thumbUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        const _ShimmerTile(),
                    errorWidget: (_, __, ___) => Container(
                      color: Colors.black38,
                      child: const Icon(
                        Icons.broken_image,
                        color: Colors.white54,
                        size: 18,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _ShimmerTile extends StatefulWidget {
  const _ShimmerTile();

  @override
  State<_ShimmerTile> createState() => _ShimmerTileState();
}

class _ShimmerTileState extends State<_ShimmerTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-1 + _c.value * 2, 0),
              end: Alignment(1 + _c.value * 2, 0),
              colors: const [
                Color(0xFF1F1F1F),
                Color(0xFF2A2A2A),
                Color(0xFF1F1F1F),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DividerBar extends StatelessWidget {
  const _DividerBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 120,
      margin: const EdgeInsets.only(right: 16),
      color: Colors.white12,
    );
  }
}

class _DashedRectangle extends StatelessWidget {
  final Size size;
  final Color color;
  const _DashedRectangle({
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: size,
      painter: _DashedPainter(color: color),
    );
  }
}

class _DashedPainter extends CustomPainter {
  final Color color;
  _DashedPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    const dash = 10.0;
    const gap = 6.0;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width, size.height),
      const Radius.circular(16),
    );

    final path = Path()..addRRect(rrect);
    final metrics = path.computeMetrics();
    for (final m in metrics) {
      var dist = 0.0;
      while (dist < m.length) {
        final extract = m.extractPath(dist, dist + dash);
        canvas.drawPath(extract, paint);
        dist += dash + gap;
      }
    }

    // Corner brackets
    final bracket = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const len = 22.0;
    canvas.drawLine(
      const Offset(0, 0),
      const Offset(len, 0),
      bracket,
    );
    canvas.drawLine(
      const Offset(0, 0),
      const Offset(0, len),
      bracket,
    );
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width - len, 0),
      bracket,
    );
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width, len),
      bracket,
    );
    canvas.drawLine(
      Offset(0, size.height),
      Offset(len, size.height),
      bracket,
    );
    canvas.drawLine(
      Offset(0, size.height),
      Offset(0, size.height - len),
      bracket,
    );
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width - len, size.height),
      bracket,
    );
    canvas.drawLine(
      Offset(size.width, size.height),
      Offset(size.width, size.height - len),
      bracket,
    );
  }

  @override
  bool shouldRepaint(covariant _DashedPainter old) =>
      old.color != color;
}