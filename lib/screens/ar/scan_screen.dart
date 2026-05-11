// lib/screens/ar/scan_screen.dart
// OBOIA — Room scanning UI (Phase 1)

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../services/ar_service.dart';

const Color goldColor = Color(0xFFFFD369);

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final ARService _arService = ARService.instance;
  StreamSubscription<AREvent>? _eventSub;
  List<DetectedSurface> _surfaces = [];
  List<DetectedObject> _objects = [];
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    setState(() => _isScanning = true);
    _eventSub = _arService.events.listen(_onAREvent);
    await _arService.setARMode('scanning');
    await _arService.startScan();
  }

  void _onAREvent(AREvent event) {
    if (event.type == 'scanUpdate') {
      final dataStr = event.data['data'] as String? ?? '';
      if (dataStr.isNotEmpty) {
        try {
          final Map<String, dynamic> json = jsonDecode(dataStr);
          final List<dynamic> surfaceList = json['surfaces'] ?? [];
          final List<dynamic> objectList = json['objects'] ?? [];
          setState(() {
            _surfaces = surfaceList.map((e) => DetectedSurface.fromJson(e)).toList();
            _objects = objectList.map((e) => DetectedObject.fromJson(e)).toList();
          });
        } catch (_) {}
      }
    } else if (event.type == 'scanComplete') {
      setState(() => _isScanning = false);
      Navigator.of(context).pop(_surfaces);
    }
  }

  Future<void> _stopScan() async {
    await _arService.stopScan();
  }

  void _toggleSurfaceExclusion(String id) {
    _arService.toggleSurfaceExclusion(id);
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 32,
              left: 16,
              right: 16,
              child: _isScanning
                  ? const Text(
                      'Move your device slowly around the room...',
                      style: TextStyle(color: Colors.white, fontSize: 18),
                      textAlign: TextAlign.center,
                    )
                  : const Text(
                      'Scan complete!',
                      style: TextStyle(color: Colors.greenAccent, fontSize: 18),
                      textAlign: TextAlign.center,
                    ),
            ),
            Positioned(
              bottom: 120,
              left: 0,
              right: 0,
              child: SizedBox(
                height: 200,
                child: ListView.builder(
                  itemCount: _surfaces.length,
                  itemBuilder: (context, index) {
                    final surface = _surfaces[index];
                    final isExcluded = surface.excluded;
                    return ListTile(
                      leading: Icon(
                        _iconForType(surface.type),
                        color: isExcluded ? Colors.grey : goldColor,
                      ),
                      title: Text(
                        '${surface.type} ${index + 1}',
                        style: TextStyle(
                          color: isExcluded ? Colors.grey : Colors.white,
                          decoration: isExcluded ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      subtitle: Text(
                        '${surface.width.toStringAsFixed(1)} × ${surface.height.toStringAsFixed(1)} m²',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      trailing: Switch(
                        value: !isExcluded,
                        onChanged: (_) => _toggleSurfaceExclusion(surface.id),
                        activeColor: goldColor,
                      ),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              bottom: 48,
              left: 40,
              right: 40,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isScanning ? Colors.grey : goldColor,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                ),
                onPressed: _isScanning ? _stopScan : null,
                child: Text(
                  _isScanning ? 'Done Scanning' : 'Processing...',
                  style: const TextStyle(fontSize: 18, color: Colors.black),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'wall': return Icons.dashboard;
      case 'door': return Icons.door_front_door;
      case 'window': return Icons.window;
      case 'opening': return Icons.arrow_right_alt;
      default: return Icons.help_outline;
    }
  }
}

class DetectedSurface {
  final String id;
  final String type;
  final double width;
  final double height;
  final double area;
  final bool excluded;

  DetectedSurface({
    required this.id,
    required this.type,
    required this.width,
    required this.height,
    required this.area,
    this.excluded = false,
  });

  factory DetectedSurface.fromJson(Map<String, dynamic> json) {
    return DetectedSurface(
      id: json['id'] as String,
      type: json['type'] as String,
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      area: (json['area'] as num).toDouble(),
      excluded: json['excluded'] as bool? ?? false,
    );
  }
}

class DetectedObject {
  final String id;
  final String type;
  final bool excluded;

  DetectedObject({required this.id, required this.type, this.excluded = false});

  factory DetectedObject.fromJson(Map<String, dynamic> json) {
    return DetectedObject(
      id: json['id'] as String,
      type: json['type'] as String,
      excluded: json['excluded'] as bool? ?? false,
    );
  }
}
