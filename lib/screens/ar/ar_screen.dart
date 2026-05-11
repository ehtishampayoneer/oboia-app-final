// lib/screens/ar/ar_screen.dart
// OBOIA — Main AR Screen with Scan + Wallpaper + Eraser
// Adjusted to accept the calling convention used in main.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/ar_service.dart';
import '../../models/wallpaper_model.dart';
import '../../models/shop_model.dart';
import 'scan_screen.dart';

const Color goldColor = Color(0xFFFFD369);

class ARScreen extends StatefulWidget {
  final WallpaperModel wallpaper;
  final double pricePerRoll;

  // Accept the old parameter names for backward compatibility.
  // `initialWallpaper` is required – the caller (main.dart) always provides it.
  ARScreen({
    super.key,
    WallpaperModel? initialWallpaper,
    ShopModel? initialShop,
    double? pricePerRoll,
  }) : assert(initialWallpaper != null, 'A wallpaper must be provided'),
       wallpaper = initialWallpaper!,
       pricePerRoll = pricePerRoll ?? 0.0;

  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> {
  final ARService _arService = ARService.instance;
  StreamSubscription<AREvent>? _eventSub;
  List<DetectedSurface> _scannedSurfaces = [];
  bool _hasScanSnapshot = false;

  @override
  void initState() {
    super.initState();
    _initAR();
  }

  Future<void> _initAR() async {
    await _arService.initAR();
    _eventSub = _arService.events.listen(_onAREvent);
    _launchScanFlow();
  }

  void _onAREvent(AREvent event) {
    if (event.type == 'wallpaperPlaced') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Wallpaper applied to wall ${event.wallIndex}')),
      );
    }
  }

  Future<void> _launchScanFlow() async {
    final result = await Navigator.of(context).push<List<DetectedSurface>>(
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (result != null && result.isNotEmpty) {
      setState(() {
        _scannedSurfaces = result.where((s) => s.type == 'wall').toList();
        _hasScanSnapshot = true;
      });
      for (int i = 0; i < _scannedSurfaces.length; i++) {
        _arService.placeWallpaper(
          wallpaper: widget.wallpaper,
          wallIndex: i,
          pricePerRoll: widget.pricePerRoll,
        );
      }
    }
  }

  Future<void> _enterEraserMode(int wallIndex) async {
    await _arService.selectWall(wallIndex);
    await _arService.enterCutMode(wallIndex);
  }

  Future<void> _exitEraserMode() async {
    await _arService.exitCutMode();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _arService.disposeAR();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const UiKitView(
            viewType: 'com.oboia/ar_view',
            creationParams: <String, dynamic>{},
            creationParamsCodec: StandardMessageCodec(),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        widget.wallpaper.name,
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                      ),
                      Text(
                        'Price: ${widget.pricePerRoll.toStringAsFixed(0)} UZS/roll',
                        style: const TextStyle(color: goldColor, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_hasScanSnapshot)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildWallPanel(),
            ),
        ],
      ),
    );
  }

  Widget _buildWallPanel() {
    return Container(
      height: 200,
      decoration: const BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: Text(
              'Detected Walls',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _scannedSurfaces.length,
              itemBuilder: (context, index) {
                final surface = _scannedSurfaces[index];
                return _buildWallCard(index, surface);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWallCard(int wallIndex, DetectedSurface surface) {
    return GestureDetector(
      onTap: () => _enterEraserMode(wallIndex),
      child: Container(
        width: 140,
        margin: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: goldColor.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: goldColor, width: 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Wall ${wallIndex + 1}',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '${surface.width.toStringAsFixed(1)} × ${surface.height.toStringAsFixed(1)}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            Text(
              '${surface.area.toStringAsFixed(1)} m²',
              style: const TextStyle(color: goldColor, fontSize: 12),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.brush, color: Colors.white70),
              onPressed: () => _enterEraserMode(wallIndex),
            ),
          ],
        ),
      ),
    );
  }
}
