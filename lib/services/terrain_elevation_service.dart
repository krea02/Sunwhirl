// lib/services/terrain_elevation_service.dart
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;


class TerrainElevationService {
  TerrainElevationService({
    required this.mapboxToken,
    this.zoom = 14,
    this.useHiDpi = false, // if true uses @2x (512px) tiles
    this.maxTilesInCache = 128,
  });

  final String mapboxToken;
  final int zoom;
  final bool useHiDpi;
  final int maxTilesInCache;

  final _cache = <String, _Tile>{};
  final _lru = <String>[]; // naive LRU list

  void dispose() {
    _cache.clear();
    _lru.clear();
  }

  Future<double?> sampleElevationM(double lat, double lon) async {
    final z = zoom;
    final n = math.pow(2.0, z).toDouble();
    final latRad = lat * math.pi / 180.0;

    final xFloat = (lon + 180.0) / 360.0 * n;
    final yFloat = (1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) / 2.0 * n;

    final x = xFloat.floor();
    final y = yFloat.floor();
    final key = "$z/$x/$y${useHiDpi ? '@2x' : ''}";

    final tile = _cache[key] ?? await _loadTile(z, x, y, key);
    if (tile.image == null) return null;

    final size = tile.size; // 256 or 512

    final px = ((xFloat - x) * size).clamp(0.0, size.toDouble() - 1e-6);
    final py = ((yFloat - y) * size).clamp(0.0, size.toDouble() - 1e-6);

    final x0 = px.floor(), y0 = py.floor();
    final x1 = (x0 + 1).clamp(0, size - 1);
    final y1 = (y0 + 1).clamp(0, size - 1);
    final fx = px - x0;
    final fy = py - y0;

    final v00 = _elevAt(tile.image!, x0, y0);
    final v10 = _elevAt(tile.image!, x1, y0);
    final v01 = _elevAt(tile.image!, x0, y1);
    final v11 = _elevAt(tile.image!, x1, y1);

    final v0 = v00 * (1 - fx) + v10 * fx;
    final v1 = v01 * (1 - fx) + v11 * fx;
    return v0 * (1 - fy) + v1 * fy;
  }

  Future<_Tile> _loadTile(int z, int x, int y, String key) async {
    if (_cache.length >= maxTilesInCache) {
      final victim = _lru.isNotEmpty ? _lru.removeAt(0) : null;
      if (victim != null) _cache.remove(victim);
    }

    final scale = useHiDpi ? "@2x" : "";
    final url =
        "https://api.mapbox.com/v4/mapbox.terrain-rgb/$z/$x/$y$scale.pngraw?access_token=$mapboxToken";

    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final decoded = img.decodeImage(resp.bodyBytes);
        final tile = _Tile(
          key: key,
          image: decoded,
          size: decoded?.width ?? (useHiDpi ? 512 : 256),
        );
        _cache[key] = tile;
        _lru.add(key);
        return tile;
      }
    } catch (_) {}

    final fallback = _Tile(key: key, image: null, size: useHiDpi ? 512 : 256);
    _cache[key] = fallback;
    _lru.add(key);
    return fallback;
  }

  double _elevAt(img.Image image, int x, int y) {
    final p = image.getPixel(x, y); // image ^4.x
    final r = p.r, g = p.g, b = p.b;
    return -10000.0 + (r * 256.0 * 256.0 + g * 256.0 + b) * 0.1;
  }
}

class _Tile {
  _Tile({required this.key, required this.image, required this.size});
  final String key;
  final img.Image? image;
  final int size;
}
