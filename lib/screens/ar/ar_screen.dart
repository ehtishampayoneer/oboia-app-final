// lib/screens/ar/ar_screen.dart

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'scan_screen.dart';
import 'package:provider/provider.dart';

import '../../models/wallpaper_model.dart';
import '../../models/shop_model.dart';
import '../../providers/cart_provider.dart';
import '../../providers/shop_provider.dart';
import '../../services/ar_service.dart';
import '../../services/texture_cache_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/debug_overlay.dart';
import '../../widgets/scanning_overlay.dart';

class ARScreen extends StatefulWidget {
  /// Optional wallpaper to open the screen with.
  /// If null, the screen falls back to ShopProvider.initialWallpaper, then
  /// to user picking from the bottom bar.
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

  // Cut counts per wall
  final Map<int, int> _cutCounts = {};

  // Lock state per wall
  final Map<int, bool> _wallLocked = {};

  // Auto-lock timer per wall (cancelled on movement)
  final Map<int, Timer> _autoLockTimers = {};

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
  bool _preloadInFlight = false;

  // Cut mode state
  bool _inCutMode = false;
  String _activeTool = 'smart';
  int? _cutModeWallIndex;

  // Obstacle hint flash
  bool _obstacleHintVisible = false;
  Timer? _obstacleHintTimer;

  // Provider listener handle so we can detach on dispose
  VoidCallback? _shopProviderListener;

  // Track which wallpaper IDs we've already preloaded so we don't
  // re-download them every time the provider notifies.
  final Set<String> _preloadedWallpaperIds = {};

  // CHANGED: Manual mode state ─────────────────────────────────────────────
  /// True while native manual-corner overlay is shown
  bool _inManualMode = false;

  /// True when native has emitted suggestManual and we haven't resolved it yet
  bool _showManualSuggestion = false;

  /// 0..4 — how many corners the user has captured
  int _manualCornerCount = 0;

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
    final shopProvider = context.read<ShopProvider>();
    _currentShop = widget.initialShop ?? shopProvider.currentShop;

    _pending ??= shopProvider.initialWallpaper;

    if (_sub == null) {
      _boot();
    }
  }

  Future<void> _boot() async {
    debugPrint('[AR] boot: starting');
    _sub = _ar.events.listen(_onAREvent);
    await _ar.initAR();
    debugPrint('[AR] boot: AR init done');

    // Phase 1: kick off the scan flow as soon as AR is initialised.
    // Defer to next frame so the AR screen has rendered its scaffold first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _launchScanFlow();
    });

    if (_currentShop == null) {
      debugPrint('[AR] boot: no shop — marking preload done');
      setState(() => _preloadDone = true);
      return;
    }

    debugPrint('[AR] boot: shop=${_currentShop!.id}');
    final shopProvider = context.read<ShopProvider>();

    shopProvider.startListeningToWallpapers(_currentShop!.id);
    debugPrint('[AR] boot: listener started');

    // Also start listeners for any other shops we already know about,
    // so the bottom bar can show their wallpapers too.
    for (final s in shopProvider.shops) {
      shopProvider.startListeningToWallpapers(s.id);
    }

    _pending ??= shopProvider.initialWallpaper;

    _shopProviderListener = () {
      if (!mounted) return;
      debugPrint('[AR] provider notified — kicking preload');
      _kickPreload();
      setState(() {});
    };
    shopProvider.addListener(_shopProviderListener!);

    _kickPreload();
    debugPrint('[AR] boot: first kickPreload done');

    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      debugPrint('[AR] fallback retry: kicking preload again');
      _kickPreload();
    });
  }

  void _kickPreload() {
    if (_preloadInFlight) {
      debugPrint('[AR] kickPreload: already in flight');
      return;
    }
    debugPrint(
        '[AR] kickPreload: shop=${_currentShop?.id}, wallpapers=${context.read<ShopProvider>().wallpapersForShop(_currentShop?.id ?? "").length}');
    if (_currentShop == null) {
      setState(() => _preloadDone = true);
      return;
    }

    final shopProvider = context.read<ShopProvider>();
    final wallpapers = shopProvider.wallpapersForShop(_currentShop!.id);
    debugPrint(
        '[AR] kickPreload: ${wallpapers.length} wallpapers in cache for ${_currentShop!.id}');

    if (wallpapers.isEmpty) {
      setState(() {
        _preloadDone = true;
        _preloadProgress = 1.0;
      });
      return;
    }

    final newWallpapers = wallpapers
        .where((w) => !_preloadedWallpaperIds.contains(w.id))
        .toList();
    if (newWallpapers.isEmpty) {
      debugPrint('[AR] kickPreload: nothing new');
      setState(() {
        _preloadDone = true;
        _preloadProgress = 1.0;
      });
      return;
    }

    final urls = <String>[];
    for (final w in newWallpapers) {
      if (w.pbr.albedoUrl.isNotEmpty) urls.add(w.pbr.albedoUrl);
      if (w.pbr.normalUrl.isNotEmpty) urls.add(w.pbr.normalUrl);
      if (w.pbr.roughnessUrl.isNotEmpty) urls.add(w.pbr.roughnessUrl);
      if (w.pbr.aoUrl.isNotEmpty) urls.add(w.pbr.aoUrl);
      final thumb = w.thumbnailUrl;
      if (thumb != null && thumb.isNotEmpty) urls.add(thumb);
    }

    if (urls.isEmpty) {
      debugPrint('[AR] kickPreload: wallpapers exist but no URLs');
      for (final w in newWallpapers) {
        _preloadedWallpaperIds.add(w.id);
      }
      setState(() {
        _preloadDone = true;
        _preloadProgress = 1.0;
      });
      return;
    }

    debugPrint('[AR] kickPreload: downloading ${urls.length} URLs');
    _preloadInFlight = true;
    setState(() {
      _preloadDone = false;
      _preloadProgress = 0.0;
    });

    unawaited(
      _cache
          .preloadShopTextures(
        textureUrls: urls,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _preloadProgress = p;
            _preloadDone = p >= 1.0;
          });
        },
      )
          .then((_) {
        _preloadInFlight = false;
        for (final w in newWallpapers) {
          _preloadedWallpaperIds.add(w.id);
        }
        debugPrint('[AR] kickPreload: complete');
      }).catchError((e) {
        _preloadInFlight = false;
        debugPrint('[AR] kickPreload error: $e');
        if (mounted) {
          setState(() => _preloadDone = true);
        }
      }),
    );
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _sub?.cancel();
    if (_shopProviderListener != null) {
      try {
        context.read<ShopProvider>().removeListener(_shopProviderListener!);
      } catch (_) {}
    }
    for (final t in _autoLockTimers.values) {
      t.cancel();
    }
    _obstacleHintTimer?.cancel();
    _ar.disposeAR();
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
    super.dispose();
  }

  // ── Native event handling ───────────────────────────────────────────────

  Future<void> _onAREvent(AREvent e) async {
    debugPrint('[AR] event: ${e.type} data=${e.data}');
    switch (e.type) {
      case 'boot':
        // Native sends this on startup with the build tag.
        debugPrint('[AR] NATIVE BOOTED build=${e.data["build"]}');
        break;

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
          // Once any wall is detected (auto OR manual), the suggestion dialog
          // is no longer relevant.
          _showManualSuggestion = false;
        });
        // Phase 1: auto-apply on wallDetected is DISABLED.
        // Walls now come from RoomPlan via scan_screen.dart, and the user
        // explicitly taps a wall to apply wallpaper (Patch 2 brings tap-select).
        // The legacy auto-apply lived here — kept as a comment for traceability.
        // if (_pending != null && _wallpaperByWall[idx] == null) {
        //   await _placeOn(idx, _pending!);
        // }
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
        // Phase 1: auto-lock disabled. The user controls wall locking
        // explicitly in the wallpaper-application UI (Phase 4).
        _autoLockTimers[idx]?.cancel();
        // if (_wallpaperByWall[idx] != null && _wallLocked[idx] != true) {
        //   _scheduleAutoLock(idx);
        // }
        break;

      case 'wallSelected':
        final idx = e.wallIndex;
        if (idx == null) return;
        setState(() => _selectedWallIndex = idx);
        break;

      case 'wallpaperPlaced':
        final idx = e.wallIndex;
        if (idx != null) {
          _scheduleAutoLock(idx);
        }
        break;

      case 'cutUpdate':
        final idx = e.wallIndex;
        final count = e.cutCount;
        if (idx == null || count == null) return;
        setState(() => _cutCounts[idx] = count);
        HapticFeedback.lightImpact();
        break;

      case 'cutToolChanged':
        final tool = e.tool;
        if (tool == null) return;
        setState(() => _activeTool = tool);
        break;

      case 'cutModeDone':
        setState(() {
          _inCutMode = false;
          _cutModeWallIndex = null;
        });
        break;

      case 'wallLockChanged':
        final idx = e.wallIndex;
        final locked = e.data['locked'] as bool?;
        if (idx == null || locked == null) return;
        setState(() => _wallLocked[idx] = locked);
        break;

      case 'obstacleHint':
        _showObstacleHint();
        break;

      case 'sessionInterrupted':
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('AR paused — bring camera back to room'),
              duration: Duration(seconds: 2),
              backgroundColor: Colors.black87,
            ),
          );
        }
        break;

      case 'sessionResumed':
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('AR tracking resumed'),
              duration: Duration(milliseconds: 800),
              backgroundColor: Colors.black87,
            ),
          );
        }
        break;

      // ── CHANGED: Manual mode events ──────────────────────────────────────
      case 'suggestManual':
        // Only show the dialog if no walls have been detected yet AND
        // we're not already in manual mode.
        if (_walls.isEmpty && !_inManualMode) {
          setState(() => _showManualSuggestion = true);
          HapticFeedback.lightImpact();
        }
        break;

      case 'manualModeEntered':
        setState(() {
          _inManualMode = true;
          _manualCornerCount = 0;
          _showManualSuggestion = false;
        });
        break;

      case 'manualModeExited':
        setState(() {
          _inManualMode = false;
          _manualCornerCount = 0;
        });
        break;

      case 'manualCornerAdded':
        final n = e.cornerNumber;
        if (n == null) return;
        setState(() => _manualCornerCount = n);
        HapticFeedback.lightImpact();
        break;

      case 'manualReset':
        setState(() => _manualCornerCount = 0);
        break;

      case 'manualWallFailed':
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                e.reason ?? 'Try tapping closer to the wall',
              ),
              backgroundColor: Colors.black87,
              duration: const Duration(seconds: 2),
            ),
          );
        }
        HapticFeedback.heavyImpact();
        break;

      case 'manualWallReady':
        // Native also emits wallDetected which the existing handler above
        // will pick up. Just clear the manual UI state here.
        setState(() {
          _inManualMode = false;
          _manualCornerCount = 0;
        });
        HapticFeedback.mediumImpact();
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

  void _scheduleAutoLock(int wallIndex) {
    _autoLockTimers[wallIndex]?.cancel();
    _autoLockTimers[wallIndex] = Timer(
      const Duration(milliseconds: 1500),
      () async {
        if (!mounted) return;
        if (_wallpaperByWall[wallIndex] == null) return;
        if (_wallLocked[wallIndex] == true) return;
        try {
          await _ar.lockWall(wallIndex: wallIndex, locked: true);
        } catch (_) {}
      },
    );
  }

  void _showObstacleHint() {
    _obstacleHintTimer?.cancel();
    if (mounted) {
      setState(() => _obstacleHintVisible = true);
    }
    _obstacleHintTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _obstacleHintVisible = false);
    });
  }

  Future<void> _placeOn(int wallIndex, WallpaperModel wallpaper) async {
    debugPrint('[AR] placeOn $wallIndex with ${wallpaper.name}');
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
      debugPrint('[AR] placeOn error: ${e.code} ${e.message}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message ?? 'Failed to place wallpaper'),
          backgroundColor: Colors.red.shade900,
        ),
      );
    }
  }

  // CHANGED: Manual mode controls ────────────────────────────────────────
  Future<void> _enterManualMode() async {
    HapticFeedback.lightImpact();
    setState(() => _showManualSuggestion = false);
    try {
      await _ar.enterManualMode();
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not enter manual mode')),
      );
    }
  }

  Future<void> _exitManualMode() async {
    try {
      await _ar.exitManualMode();
    } catch (_) {}
    setState(() {
      _inManualMode = false;
      _manualCornerCount = 0;
    });
  }

  void _dismissManualSuggestion() {
    setState(() => _showManualSuggestion = false);
  }

  Future<void> _handleBack() async {
    if (_inManualMode) {
      await _exitManualMode();
      return;
    }
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  // Cut-mode controls
  Future<void> _enterCutMode() async {
    final idx = _selectedWallIndex;
    if (idx == null || _wallpaperByWall[idx] == null) return;
    if (_wallLocked[idx] == true) {
      await _ar.lockWall(wallIndex: idx, locked: false);
    }
    try {
      await _ar.enterCutMode(idx);
      setState(() {
        _inCutMode = true;
        _cutModeWallIndex = idx;
        _activeTool = 'smart';
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Could not enter cut mode')),
      );
    }
  }

  Future<void> _exitCutMode() async {
    try {
      await _ar.exitCutMode();
    } catch (_) {}
    setState(() {
      _inCutMode = false;
      _cutModeWallIndex = null;
    });
  }

  Future<void> _setCutTool(String tool) async {
    setState(() => _activeTool = tool);
    HapticFeedback.selectionClick();
  }

  Future<void> _undoLastCut() async {
    final idx = _cutModeWallIndex;
    if (idx == null) return;
    try {
      await _ar.undoCut(idx);
      HapticFeedback.lightImpact();
    } catch (_) {}
  }

  Future<void> _clearAllCuts() async {
    final idx = _cutModeWallIndex;
    if (idx == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Clear all cuts?',
            style: TextStyle(color: Colors.white)),
        content: const Text('This removes every cut on this wall.',
            style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _ar.clearAllCuts(idx);
      HapticFeedback.mediumImpact();
    } catch (_) {}
  }

  Future<void> _toggleLock() async {
    final idx = _selectedWallIndex;
    if (idx == null) return;
    final currentlyLocked = _wallLocked[idx] == true;
    try {
      await _ar.lockWall(wallIndex: idx, locked: !currentlyLocked);
    } catch (_) {}
  }

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_inManualMode,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && _inManualMode) {
          await _exitManualMode();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _buildNativeARView(),

            // Scanning overlay — always rendered so it can fade in/out smoothly.
            // Fades out the moment any wall is captured (auto OR manual)
            // or any other special mode is entered.
            ScanningOverlay(
              visible: _walls.isEmpty && !_inCutMode && !_inManualMode,
              pointCount: 0,
            ),

            // Top bar shown except in cut mode
            if (!_inCutMode) _buildTopBar(),
            if (_inCutMode) _buildCutModeTopBar(),

            // Wall selector only shown when not in cut/manual mode
            if (_walls.length > 1 && !_inCutMode && !_inManualMode)
              _buildWallSelector(),

            // Measurements card only when a wall exists & not in special modes
            if (_selectedWallIndex != null &&
                _walls.isNotEmpty &&
                !_inCutMode &&
                !_inManualMode)
              _buildMeasurementsCard(),

            if (_inCutMode) _buildCutCountChip(),

            // Bottom wallpaper bar — hidden in cut & manual modes
            if (!_inCutMode && !_inManualMode) _buildBottomBar(),

            if (!_preloadDone && !_inCutMode && !_inManualMode)
              _buildPreloadChip(),

            if (_obstacleHintVisible && !_inCutMode && !_inManualMode)
              _buildObstacleHintChip(),

            if (_isLockedAndIdle()) _buildLockedPill(),

            // CHANGED: "Mark wall manually" pill in scanning overlay
            if (_walls.isEmpty &&
                !_inCutMode &&
                !_inManualMode &&
                !_showManualSuggestion)
              _buildManualEntryButton(),

            // CHANGED: Friendly suggestion dialog when auto-detect fails
            if (_showManualSuggestion &&
                _walls.isEmpty &&
                !_inCutMode &&
                !_inManualMode)
              _buildManualSuggestionDialog(),

            const DebugOverlay(filter: '[AR]'),

            // Diagnostic log viewer button — top-left under back button
            Positioned(
              top: MediaQuery.of(context).padding.top + 70,
              left: 16,
              child: GestureDetector(
                onTap: _openLogViewer,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFFFFD369).withValues(alpha: 0.4),
                      width: 1,
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bug_report,
                          size: 14, color: Color(0xFFFFD369)),
                      SizedBox(width: 6),
                      Text(
                        'Show Logs',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchScanFlow() async {
    debugPrint('[AR] launching scan flow');
    final ScanSnapshot? snap = await Navigator.of(context).push<ScanSnapshot>(
      MaterialPageRoute(
        builder: (_) => const ScanScreen(),
        fullscreenDialog: true,
      ),
    );
    if (!mounted) return;

    if (snap == null) {
      debugPrint('[AR] scan returned no snapshot — user cancelled');
      // User backed out without finishing. Pop the AR screen entirely.
      Navigator.of(context).maybePop();
      return;
    }

    debugPrint('[AR] scan complete: walls=${snap.wallCount} doors=${snap.doorCount} windows=${snap.windowCount}');
    // Phase 1: switch native AR into preview mode so it stops listening
    // to ARKit plane detection. Phase 2 will use the snapshot's surfaces
    // to render outlines and accept tap-to-apply gestures.
    try {
      await _ar.setARMode('preview');
    } catch (e) {
      debugPrint('[AR] setARMode failed: $e');
    }
  }

  void _openLogViewer() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const _LogViewerScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  bool _isLockedAndIdle() {
    if (_inCutMode || _inManualMode) return false;
    final idx = _selectedWallIndex;
    if (idx == null) return false;
    return _wallLocked[idx] == true && _wallpaperByWall[idx] != null;
  }

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

  // CHANGED: Old _buildScanningOverlay removed. The new ScanningOverlay widget
  // is wired directly into the Stack in the build method above.
  // _scanCtrl is kept for potential future use by other animated UI.

  // CHANGED: Always-available "Mark manually" pill near bottom of scanning view
  Widget _buildManualEntryButton() {
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 200,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: _enterManualMode,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: AppTheme.gold.withValues(alpha: 0.5),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.touch_app, size: 16, color: AppTheme.gold),
                    SizedBox(width: 8),
                    Text(
                      'Mark wall manually',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // CHANGED: Friendly auto-suggestion dialog after 5s of failed detection
  Widget _buildManualSuggestionDialog() {
    return Positioned(
      bottom: MediaQuery.of(context).padding.bottom + 180,
      left: 24,
      right: 24,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: AppTheme.gold.withValues(alpha: 0.6),
                    width: 1.4,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.lightbulb_outline,
                      color: AppTheme.gold,
                      size: 28,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Plain wall?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Mark the corners by tapping — works on any wall, even blank ones.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GestureDetector(
                          onTap: _dismissManualSuggestion,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.25),
                              ),
                            ),
                            child: const Text(
                              'Keep trying',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: _enterManualMode,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.gold,
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.gold.withValues(alpha: 0.4),
                                  blurRadius: 12,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: const Text(
                              'Mark manually',
                              style: TextStyle(
                                color: Colors.black,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
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
        ),
      ),
    );
  }

  Widget _buildMeasurementsCard() {
    final m = _walls[_selectedWallIndex];
    if (m == null) return const SizedBox.shrink();

    final wallpaper = _wallpaperByWall[_selectedWallIndex] ??
        _pending ??
        widget.initialWallpaper;
    if (wallpaper == null) return const SizedBox.shrink();

    final rolls = m.rollsNeeded(
      rollWidth: wallpaper.rollWidth,
      rollLength: wallpaper.rollLength,
    );
    final total = rolls * wallpaper.pricePerRoll;
    final hasWallpaperPlaced = _wallpaperByWall[_selectedWallIndex] != null;
    final cutCount = _cutCounts[_selectedWallIndex] ?? 0;

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
                    const Spacer(),
                    if (hasWallpaperPlaced)
                      _CutModeButton(
                        cutCount: cutCount,
                        onTap: _enterCutMode,
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Wall ${i + 1}',
                        style: TextStyle(
                          color: _selectedWallIndex == i
                              ? Colors.black
                              : Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                      if (_wallLocked[i] == true) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.lock,
                          size: 12,
                          color: _selectedWallIndex == i
                              ? Colors.black
                              : Colors.white,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

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
            onPressed: _handleBack,
          ),
          // Cart hidden in manual mode (the screen is for tapping corners)
          if (!_inManualMode)
            _AddToCartButton(
              count: cart.totalItems,
              onTap: _addCurrentToCart,
            ),
        ],
      ),
    );
  }

  Widget _buildCutModeTopBar() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 8,
      left: 12,
      right: 12,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: AppTheme.gold.withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              children: [
                _CutToolButton(
                  icon: Icons.center_focus_strong,
                  active: _activeTool == 'smart',
                  onTap: () => _setCutTool('smart'),
                  tooltip: 'Tap socket / switch',
                ),
                _CutToolButton(
                  icon: Icons.gesture,
                  active: _activeTool == 'draw',
                  onTap: () => _setCutTool('draw'),
                  tooltip: 'Freehand',
                ),
                _CutToolButton(
                  icon: Icons.crop_square,
                  active: _activeTool == 'rect',
                  onTap: () => _setCutTool('rect'),
                  tooltip: 'Rectangle',
                ),
                _CutToolButton(
                  icon: Icons.circle_outlined,
                  active: _activeTool == 'circle',
                  onTap: () => _setCutTool('circle'),
                  tooltip: 'Circle',
                ),
                Container(
                  width: 1,
                  height: 24,
                  color: Colors.white24,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                ),
                _CutActionButton(
                  icon: Icons.undo,
                  onTap: _undoLastCut,
                  tooltip: 'Undo',
                ),
                _CutActionButton(
                  icon: Icons.delete_sweep_outlined,
                  onTap: _clearAllCuts,
                  tooltip: 'Clear all',
                ),
                const Spacer(),
                _DoneButton(onTap: _exitCutMode),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCutCountChip() {
    final count = _cutCounts[_cutModeWallIndex] ?? 0;
    if (count == 0) return const SizedBox.shrink();
    return Positioned(
      top: MediaQuery.of(context).padding.top + 76,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: ClipRRect(
            key: ValueKey(count),
            borderRadius: BorderRadius.circular(12),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.gold.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.content_cut,
                        size: 14, color: AppTheme.gold),
                    const SizedBox(width: 6),
                    Text(
                      '$count cut${count == 1 ? '' : 's'} applied',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLockedPill() {
    return Positioned(
      bottom: 184,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: _toggleLock,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: AppTheme.gold.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.lock, size: 14, color: AppTheme.gold),
                    SizedBox(width: 6),
                    Text(
                      'Locked · tap to rescan',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildObstacleHintChip() {
    return Positioned(
      bottom: 200,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: _obstacleHintVisible ? 1 : 0,
          duration: const Duration(milliseconds: 250),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: AppTheme.gold.withValues(alpha: 0.4),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.auto_fix_high, size: 14, color: AppTheme.gold),
                    SizedBox(width: 6),
                    Text(
                      'Sockets detected — open Cut Mode',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
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
    final wp = _wallpaperByWall[sel] ?? _pending ?? widget.initialWallpaper;

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
          if (wallpapers.isEmpty)
            Container(
              width: 120,
              height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: const Text(
                'No wallpapers',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            )
          else
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
      if (_wallLocked[sel] == true) {
        await _ar.lockWall(wallIndex: sel, locked: false);
      }
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
                    value: _preloadProgress == 0 ? null : _preloadProgress,
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

class _CutModeButton extends StatelessWidget {
  final int cutCount;
  final VoidCallback onTap;
  const _CutModeButton({required this.cutCount, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.gold,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.content_cut, size: 14, color: Colors.black),
            const SizedBox(width: 6),
            Text(
              cutCount == 0 ? 'Cut' : 'Cut · $cutCount',
              style: const TextStyle(
                color: Colors.black,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CutToolButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final String tooltip;

  const _CutToolButton({
    required this.icon,
    required this.active,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 44,
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          decoration: BoxDecoration(
            color: active ? AppTheme.gold : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            icon,
            size: 20,
            color: active ? Colors.black : Colors.white70,
          ),
        ),
      ),
    );
  }
}

class _CutActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _CutActionButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Icon(icon, size: 18, color: Colors.white70),
        ),
      ),
    );
  }
}

class _DoneButton extends StatelessWidget {
  final VoidCallback onTap;
  const _DoneButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.gold,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Text(
          'Done',
          style: TextStyle(
            color: Colors.black,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
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
              color: isActive ? AppTheme.gold : Colors.transparent,
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
                    placeholder: (_, __) => const _ShimmerTile(),
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

    final bracket = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const len = 22.0;
    canvas.drawLine(const Offset(0, 0), const Offset(len, 0), bracket);
    canvas.drawLine(const Offset(0, 0), const Offset(0, len), bracket);
    canvas.drawLine(
        Offset(size.width, 0), Offset(size.width - len, 0), bracket);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, len), bracket);
    canvas.drawLine(
        Offset(0, size.height), Offset(len, size.height), bracket);
    canvas.drawLine(
        Offset(0, size.height), Offset(0, size.height - len), bracket);
    canvas.drawLine(Offset(size.width, size.height),
        Offset(size.width - len, size.height), bracket);
    canvas.drawLine(Offset(size.width, size.height),
        Offset(size.width, size.height - len), bracket);
  }

  @override
  bool shouldRepaint(covariant _DashedPainter old) => old.color != color;
}

// ─────────────────────────────────────────────────────────────────────────
// Diagnostic Log Viewer — fullscreen screen showing the in-memory ring
// buffer. Copy button puts entire log on clipboard so user can paste.
// ─────────────────────────────────────────────────────────────────────────

class _LogViewerScreen extends StatefulWidget {
  const _LogViewerScreen();

  @override
  State<_LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<_LogViewerScreen> {
  String _content = '';
  bool _showFile = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadInMemory();
  }

  void _loadInMemory() {
    setState(() {
      _content = DiagnosticLog.instance.dump();
      _showFile = false;
    });
  }

  Future<void> _loadFile() async {
    setState(() {
      _loading = true;
      _showFile = true;
    });
    final txt = await DiagnosticLog.instance.readFileLog();
    if (!mounted) return;
    setState(() {
      _content = txt.isEmpty ? '(file is empty or not yet created)' : txt;
      _loading = false;
    });
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Logs copied to clipboard'),
        duration: Duration(milliseconds: 1200),
        backgroundColor: Colors.black87,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lineCount = _content.isEmpty ? 0 : _content.split('\n').length;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          _showFile ? 'On-Disk Log' : 'In-Memory Log',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy, color: Color(0xFFFFD369)),
            tooltip: 'Copy all',
            onPressed: _copy,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            tooltip: 'Refresh',
            onPressed: _showFile ? _loadFile : _loadInMemory,
          ),
        ],
      ),
      body: Column(
        children: [
          // Mode switcher
          Container(
            color: Colors.black,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _ModeButton(
                  label: 'Memory ($lineCount lines)',
                  active: !_showFile,
                  onTap: _loadInMemory,
                ),
                const SizedBox(width: 8),
                _ModeButton(
                  label: 'File',
                  active: _showFile,
                  onTap: _loadFile,
                ),
                const Spacer(),
                Text(
                  '$lineCount lines',
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ],
            ),
          ),

          if (_loading)
            const LinearProgressIndicator(
              backgroundColor: Colors.black,
              valueColor: AlwaysStoppedAnimation(Color(0xFFFFD369)),
            ),

          // Log content
          Expanded(
            child: Container(
              color: const Color(0xFF0A0A0A),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  _content.isEmpty ? '(no log entries yet)' : _content,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontFamily: 'Courier',
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? const Color(0xFFFFD369).withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active
                ? const Color(0xFFFFD369)
                : Colors.white.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? const Color(0xFFFFD369) : Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
