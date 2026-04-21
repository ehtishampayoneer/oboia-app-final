// lib/services/texture_cache_service.dart
//
// Preloads and caches Firebase Storage PBR texture URLs so that switching
// wallpapers in AR is instant. Memory + disk tiers; disk path is handed
// to the native side via the AR method channel.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class TextureCacheService {
  TextureCacheService._();
  static final TextureCacheService instance = TextureCacheService._();

  final Map<String, Uint8List> _memory = {};
  final Map<String, Completer<String?>> _inflight = {};
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 60),
    responseType: ResponseType.bytes,
  ));

  Directory? _cacheDir;
  static const int _maxDiskBytes = 200 * 1024 * 1024; // 200 MB
  static const int _maxMemoryEntries = 32;
  DateTime _lastTrim = DateTime.fromMillisecondsSinceEpoch(0);

  // ── Directory setup ──────────────────────────────────────────────────────

  Future<Directory> _dir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getTemporaryDirectory();
    final d = Directory('${base.path}/oboia_pbr_textures');
    if (!await d.exists()) await d.create(recursive: true);
    _cacheDir = d;
    return d;
  }

  String _keyFor(String url) =>
      sha256.convert(url.codeUnits).toString();

  Future<File> _fileFor(String url) async =>
      File('${(await _dir()).path}/${_keyFor(url)}');

  // ── Public API ───────────────────────────────────────────────────────────

  /// True if the URL bytes are cached on disk or memory.
  Future<bool> isCached(String url) async {
    if (url.isEmpty) return false;
    if (_memory.containsKey(url)) return true;
    final f = await _fileFor(url);
    return f.existsSync() && await f.length() > 0;
  }

  /// Local filesystem path for the cached bytes.
  /// Returns null if not cached yet.
  Future<String?> getLocalPath(String url) async {
    if (url.isEmpty) return null;
    final f = await _fileFor(url);
    if (f.existsSync() && await f.length() > 0) return f.path;
    return null;
  }

  /// Raw bytes — pulls from memory, then disk, then network.
  /// Returns null if download fails.
  Future<Uint8List?> getCached(String url) async {
    if (url.isEmpty) return null;

    // Check memory first
    final mem = _memory[url];
    if (mem != null) return mem;

    // Check disk
    final f = await _fileFor(url);
    if (f.existsSync() && await f.length() > 0) {
      final bytes = await f.readAsBytes();
      _putMemory(url, bytes);
      return bytes;
    }

    // Download and return bytes
    return _downloadAndReturnBytes(url);
  }

  /// Download URL and return bytes directly.
  Future<Uint8List?> _downloadAndReturnBytes(String url) async {
    try {
      final resp = await _dio.get<List<int>>(url);
      if (resp.statusCode == null ||
          resp.statusCode! < 200 ||
          resp.statusCode! >= 300) {
        return null;
      }
      final bytes = Uint8List.fromList(resp.data ?? const <int>[]);
      if (bytes.isEmpty) return null;

      final f = await _fileFor(url);
      await f.writeAsBytes(bytes, flush: true);
      _putMemory(url, bytes);
      _maybeTrim();
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Download URL and return local file path.
  Future<String?> _downloadOne(String url) async {
    // Coalesce concurrent downloads of the same URL
    final existing = _inflight[url];
    if (existing != null) return existing.future;

    final c = Completer<String?>();
    _inflight[url] = c;

    try {
      final resp = await _dio.get<List<int>>(url);
      if (resp.statusCode == null ||
          resp.statusCode! < 200 ||
          resp.statusCode! >= 300) {
        c.complete(null);
        return null;
      }
      final bytes = Uint8List.fromList(resp.data ?? const <int>[]);
      if (bytes.isEmpty) {
        c.complete(null);
        return null;
      }
      final f = await _fileFor(url);
      await f.writeAsBytes(bytes, flush: true);
      _putMemory(url, bytes);
      _maybeTrim();
      c.complete(f.path);
      return f.path;
    } catch (_) {
      c.complete(null);
      return null;
    } finally {
      _inflight.remove(url);
    }
  }

  void _putMemory(String url, Uint8List bytes) {
    if (_memory.length >= _maxMemoryEntries) {
      _memory.remove(_memory.keys.first);
    }
    _memory[url] = bytes;
  }

  // ── Preload shop textures ────────────────────────────────────────────────

  /// Preload every PBR map for a list of wallpapers.
  /// Reports progress from 0.0 to 1.0.
  /// Call this when AR screen opens.
  Future<void> preloadShopTextures({
    required List<String> textureUrls,
    required void Function(double progress) onProgress,
    int concurrency = 4,
  }) async {
    final urls = textureUrls
        .where((u) => u.isNotEmpty)
        .toSet()
        .toList();

    if (urls.isEmpty) {
      onProgress(1.0);
      return;
    }

    final total = urls.length;
    var done = 0;
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        final i = cursor++;
        if (i >= total) return;
        final u = urls[i];
        try {
          if (!await isCached(u)) {
            await _downloadOne(u);
          }
        } catch (_) {
          // Swallow — missing texture handled in AR layer
        }
        done++;
        onProgress(done / total);
      }
    }

    final workers = List.generate(
      concurrency.clamp(1, 8),
      (_) => worker(),
    );
    await Future.wait(workers);
    onProgress(1.0);
  }

  // ── Cache trimming ───────────────────────────────────────────────────────

  Future<void> _maybeTrim() async {
    final now = DateTime.now();
    if (now.difference(_lastTrim).inSeconds < 30) return;
    _lastTrim = now;
    await _trim();
  }

  Future<void> _trim() async {
    final d = await _dir();
    final files = d.listSync().whereType<File>().toList();
    int total = 0;
    for (final f in files) {
      total += await f.length();
    }
    if (total <= _maxDiskBytes) return;
    files.sort((a, b) =>
        a.lastModifiedSync().compareTo(b.lastModifiedSync()));
    for (final f in files) {
      if (total <= _maxDiskBytes) break;
      final len = await f.length();
      try {
        await f.delete();
        total -= len;
      } catch (_) {
        // ignore
      }
    }
  }

  Future<void> clearCache() async {
    _memory.clear();
    try {
      final d = await _dir();
      if (d.existsSync()) {
        await d.delete(recursive: true);
      }
      _cacheDir = null;
    } catch (_) {
      // ignore
    }
  }
}