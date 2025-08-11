import 'dart:math' as math;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../models/building.dart';
import '../models/place.dart';

const double _rad = math.pi / 180.0;
const double _deg = 180.0 / math.pi;
const double _dayMs = 1000 * 60 * 60 * 24.0;
const double _j2000 = 2451545.0;
const double _obliquityJ2000Rad = 23.4392911 * _rad;

double _normalizeAngleDeg(double a) {
  double b = a / 360.0;
  double n = (b - b.floor()) * 360.0;
  return n < 0 ? n + 360.0 : n;
}
double _normalizeAngleRad(double a) {
  double twoPi = 2 * math.pi;
  double n = a % twoPi;
  return n < 0 ? n + twoPi : n;
}

Map<String, double> _getSunEphemeris(double jdUt) {
  final dJ2000 = jdUt - _j2000;
  final tJc = dJ2000 / 36525.0;

  final lSunMeanDeg = _normalizeAngleDeg(280.46646 + 36000.76983 * tJc + 0.0003032 * tJc * tJc);
  final mSunMeanDeg = _normalizeAngleDeg(357.52911 + 35999.05029 * tJc - 0.0001537 * tJc * tJc);
  final mSunMeanRad = mSunMeanDeg * _rad;

  final cSunDeg =
      (1.914602 - 0.004817 * tJc - 0.000014 * tJc * tJc) * math.sin(mSunMeanRad) +
          (0.019993 - 0.000101 * tJc) * math.sin(2 * mSunMeanRad) +
          0.000289 * math.sin(3 * mSunMeanRad);

  final lambdaSunTrueDeg = _normalizeAngleDeg(lSunMeanDeg + cSunDeg);
  final lambdaSunTrueRad = lambdaSunTrueDeg * _rad;
  final epsilonRad = _obliquityJ2000Rad;

  double alphaSunRad = math.atan2(
    math.cos(epsilonRad) * math.sin(lambdaSunTrueRad),
    math.cos(lambdaSunTrueRad),
  );
  alphaSunRad = _normalizeAngleRad(alphaSunRad);

  final deltaSunRad = math.asin(math.sin(epsilonRad) * math.sin(lambdaSunTrueRad));

  final gmstDeg = _normalizeAngleDeg(
    280.46061837 + 360.985647366289 * dJ2000
        + 0.000387933 * tJc * tJc - tJc * tJc * tJc / 38710000.0,
  );

  return {
    'declination_rad': deltaSunRad,
    'right_ascension_rad': alphaSunRad,
    'gmst_deg': gmstDeg,
  };
}

double _refractionArcminBennett(double apparentAltDeg) {
  final h = apparentAltDeg.clamp(-1.0, 89.9);
  final inner = h + (10.3 / (h + 5.11));
  final innerRad = inner * _rad;
  final tanv = math.tan(innerRad);
  if (tanv.abs() < 1e-6) return 34.0;
  return 1.02 / tanv;
}

Map<String, double> _sunAzAlt(DateTime dateTime, double latRad, double lonRad) {
  final utc = dateTime.isUtc ? dateTime : dateTime.toUtc();
  final jdUt = (utc.millisecondsSinceEpoch / _dayMs) + 2440587.5;

  final eph = _getSunEphemeris(jdUt);
  final dec = eph['declination_rad']!;
  final ra  = eph['right_ascension_rad']!;
  final gastRad = eph['gmst_deg']! * _rad;
  final last = _normalizeAngleRad(gastRad + lonRad);

  double h = last - ra;
  if (h > math.pi) h -= 2 * math.pi;
  if (h < -math.pi) h += 2 * math.pi;

  final sinHGeom = (math.sin(latRad) * math.sin(dec)) +
      (math.cos(latRad) * math.cos(dec) * math.cos(h));
  final hGeom = math.asin(sinHGeom.clamp(-1.0, 1.0));

  double hDeg = hGeom * _deg;
  double refrArcmin = 0.0;
  if (hDeg > -1.0) {
    refrArcmin = _refractionArcminBennett(hDeg);
  }
  final refrRad = (refrArcmin / 60.0) * _rad;
  final hApp = (hGeom + refrRad).clamp(-math.pi / 2, math.pi / 2);

  final y = -math.cos(dec) * math.sin(h);
  final x =  math.sin(dec) * math.cos(latRad) - math.cos(dec) * math.sin(latRad) * math.cos(h);
  final az = _normalizeAngleRad(math.atan2(y, x));

  return {'az': az, 'alt': hApp};
}

class SunUtils {
  static const double rad = _rad;
  static const double deg = _deg;

  static const double metersPerDegreeLat = 111320.0;
  static const double maxShadowLength = 1500.0;
  static const double altitudeThresholdRad = -0.833 * rad;

  static const double defaultInsideBuildingCheckRadiusMeters = 0.1;

  static Map<String, double> getSunPosition(DateTime dateTime, double latDeg, double lngDeg) {
    final r = _sunAzAlt(dateTime, latDeg * rad, lngDeg * rad);
    return {'azimuth': r['az']!, 'altitude': r['alt']!};
  }

  static double metersPerPixel(double latitudeDeg, double zoom) {
    final cosLat = math.cos(latitudeDeg * rad).clamp(0.0, 1.0);
    return 156543.03392 * cosLat / math.pow(2.0, zoom);
  }

  static double metersPerDegreeLng(double latDeg) => metersPerDegreeLat * math.cos(latDeg * rad);
  static double metersToLng(double meters, double latDeg) {
    final mPerDeg = metersPerDegreeLng(latDeg);
    if (mPerDeg.abs() < 1e-7) return 0.0;
    return meters / mPerDeg;
  }
  static double metersToLat(double meters) => meters / metersPerDegreeLat;

  /// Terrain horizon: maximum terrain elevation angle (rad) along azimuth.
  static Future<double> horizonAngleRad(
      double lat, double lng, double azRad, {
        required Future<double?> Function(double lat, double lng) sampleElevationM,
        double startStepM = 25.0,
        double maxDistM = 12000.0,
      }) async {
    final z0 = await sampleElevationM(lat, lng) ?? 0.0;
    double step = startStepM;
    double d = step;
    double maxAng = 0.0;

    while (d <= maxDistM) {
      final latOff = metersToLat(d * math.cos(azRad));
      final lngOff = metersToLng(d * math.sin(azRad), lat);
      final z = await sampleElevationM(lat + latOff, lng + lngOff);
      if (z != null) {
        final ang = math.atan((z - z0) / d);
        if (ang > maxAng) maxAng = ang;
        if (maxAng > (60.0 * rad)) break;
      }
      d += step;
      step = math.min(step * 1.5, 400.0);
    }
    return maxAng;
  }

  /// Fast polygon test for “is this point within any precalculated shadow polygon”
  static bool isPointInPolygon(Position p, List<Position> poly) {
    if (poly.length < 3) return false;
    bool inside = false;
    final x = p.lng.toDouble();
    final y = p.lat.toDouble();
    const eps = 1e-9;

    for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final xi = poly[i].lng.toDouble(), yi = poly[i].lat.toDouble();
      final xj = poly[j].lng.toDouble(), yj = poly[j].lat.toDouble();

      final crosses = ((yi > y) != (yj > y));
      if (!crosses) continue;

      final dy = yj - yi;
      if (dy.abs() < eps) {
        if ((y - yi).abs() < eps &&
            x >= math.min(xi, xj) - eps &&
            x <= math.max(xi, xj) + eps) return true;
        continue;
      }

      final xInt = (xj - xi) * (y - yi) / dy + xi;
      if ((x - xInt).abs() < eps) return true;
      if (x < xInt) inside = !inside;
    }
    return inside;
  }

  /// Shadow polygon using a stitched “ribbon” (base + shifted reversed)
  static List<Position> calculateBuildingShadow({
    required Building building,
    required double sunAzimuth_N_CW_rad,
    required double sunAltitudeRad,
    double minDrawableShadowMeters = 0.5,
  }) {
    final poly = building.polygon;
    final h = math.max(0.1, building.height.toDouble());
    if (poly.length < 3 || sunAltitudeRad <= altitudeThresholdRad) return [];

    final tanAlt = math.tan(sunAltitudeRad);
    const minTan = 0.00175; // ~tan(0.1°)
    final t = tanAlt.abs() < minTan ? (tanAlt.isNegative ? -minTan : minTan) : tanAlt;

    final L = (h / t).abs();
    if (L < minDrawableShadowMeters) return [];
    final clamped = L > maxShadowLength ? maxShadowLength : L;

    final dx = -clamped * math.sin(sunAzimuth_N_CW_rad);
    final dy = -clamped * math.cos(sunAzimuth_N_CW_rad);

    final base = (poly.isNotEmpty &&
        poly.first.lat == poly.last.lat &&
        poly.first.lng == poly.last.lng)
        ? poly.sublist(0, poly.length - 1)
        : List<Position>.from(poly);

    if (base.length < 3) return [];

    final shifted = <Position>[];
    for (final v in base) {
      final lat = v.lat.toDouble();
      final lng = v.lng.toDouble();
      final sLat = lat + metersToLat(dy);
      final sLng = lng + metersToLng(dx, lat);
      shifted.add(Position(sLng, sLat));
    }

    final ring = <Position>[...base, ...shifted.reversed];
    if (ring.first.lat != ring.last.lat || ring.first.lng != ring.last.lng) {
      ring.add(ring.first);
    }
    return ring;
  }

  /// Full place-in-shadow test (uses precalculated polygons if provided + geometric fallback).
  static bool isPlaceInShadow({
    required Position placePosition,
    required double sunAzimuth_N_CW_rad,
    required double sunAltitudeRad,
    required List<Building> potentialBlockers,
    required Map<String, List<Position>> buildingShadows,
    String? ignoreBuildingId,
    double searchDistance = maxShadowLength + 100.0,
    double checkRadiusMeters = 1.25,
    double insideHostBuildingCheckRadiusMeters = defaultInsideBuildingCheckRadiusMeters,
  }) {
    final placeLat = placePosition.lat.toDouble();
    final placeLng = placePosition.lng.toDouble();

    if (sunAltitudeRad <= altitudeThresholdRad) return true;
    if (potentialBlockers.isEmpty) return false;

    final effectiveR = (ignoreBuildingId != null)
        ? insideHostBuildingCheckRadiusMeters
        : checkRadiusMeters;

    final List<Position> pts;
    if (effectiveR < 0.05) {
      pts = [placePosition];
    } else {
      final dLat = SunUtils.metersToLat(effectiveR);
      final dLng = SunUtils.metersToLng(effectiveR, placeLat);
      pts = [
        placePosition,
        Position(placeLng, placeLat + dLat),
        Position(placeLng, placeLat - dLat),
        Position(placeLng + dLng, placeLat),
        Position(placeLng - dLng, placeLat),
        Position(placeLng + dLng, placeLat + dLat),
        Position(placeLng - dLng, placeLat + dLat),
        Position(placeLng + dLng, placeLat - dLat),
        Position(placeLng - dLng, placeLat - dLat),
      ];
    }

    final ux = math.sin(sunAzimuth_N_CW_rad); // +X east
    final uy = math.cos(sunAzimuth_N_CW_rad); // +Y north

    for (final b in potentialBlockers) {
      if (b.id == ignoreBuildingId) continue;

      final cLat = (b.bounds.southwest.coordinates.lat + b.bounds.northeast.coordinates.lat) / 2.0;
      final cLng = (b.bounds.southwest.coordinates.lng + b.bounds.northeast.coordinates.lng) / 2.0;
      final dYc = (cLat - placeLat) * metersPerDegreeLat;
      final dXc = (cLng - placeLng) * metersPerDegreeLng(placeLat);
      final dist2c = dXc * dXc + dYc * dYc;
      if (dist2c > searchDistance * searchDistance) continue;

      // a) polygon shortcut if available
      final shadowPoly = buildingShadows[b.id];
      if (shadowPoly != null && shadowPoly.length >= 3) {
        for (final p in pts) {
          if (SunUtils.isPointInPolygon(p, shadowPoly)) return true;
        }
        // else fall through to geometric
      }

      // b) geometric fallback
      final t = dXc * ux + dYc * uy; // along-sun distance (m)
      if (t <= 0) continue;          // building behind the place relative to sun

      final px = -uy; // unit perpendicular (rotate sun dir by -90°)
      final py =  ux;
      final lateral = (dXc * px + dYc * py).abs();

      final w = (b.bounds.northeast.coordinates.lng - b.bounds.southwest.coordinates.lng).abs()
          * metersPerDegreeLng(placeLat);
      final h = (b.bounds.northeast.coordinates.lat - b.bounds.southwest.coordinates.lat).abs()
          * metersPerDegreeLat;
      final halfDiag = 0.5 * math.sqrt(w * w + h * h);
      final lateralAllowance = math.max(6.0, math.min(w, h) * 0.5);

      if (lateral > (lateralAllowance + halfDiag * 0.15)) continue;

      final angBlock = math.atan((b.height.toDouble().clamp(0.5, 200.0)) / t);
      if (angBlock > sunAltitudeRad) return true;
    }

    return false;
  }

  static String getIconPath(PlaceType type, bool isInSun) {
    final base = switch (type) {
      PlaceType.cafe => "cafe",
      PlaceType.pub => "pub",
      PlaceType.park => "park",
      _ => "default",
    };
    return "${base}_${isInSun ? 'sun' : 'moon'}";
  }
}
