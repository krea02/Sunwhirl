import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

import '../models/building.dart';
import '../models/place.dart';

const double _rad = math.pi / 180.0; // deg->rad
const double _deg = 180.0 / math.pi; // rad->deg
const double _dayMs = 1000 * 60 * 60 * 24.0;
const double _j2000 = 2451545.0;
const double _obliquityJ2000Rad = 23.4392911 * _rad;

// ---------- Core ephemeris ----------
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

  double alphaSunRad = math.atan2(math.cos(epsilonRad) * math.sin(lambdaSunTrueRad),
      math.cos(lambdaSunTrueRad));
  alphaSunRad = _normalizeAngleRad(alphaSunRad);

  final deltaSunRad = math.asin(math.sin(epsilonRad) * math.sin(lambdaSunTrueRad));

  final gmstDeg = _normalizeAngleDeg(
      280.46061837 + 360.985647366289 * dJ2000 + 0.000387933 * tJc * tJc - tJc * tJc * tJc / 38710000.0);

  return {
    'declination_rad': deltaSunRad,
    'right_ascension_rad': alphaSunRad,
    'gmst_deg': gmstDeg,
  };
}

// Bennett refraction helper (arcminutes) with guardrails
double _refractionArcminBennett(double apparentAltDeg) {
  // Valid-ish for -1° .. 90°. Clamp input.
  final h = apparentAltDeg.clamp(-1.0, 89.9);
  // R ≈ 1.02 / tan( h + 10.3/(h + 5.11) )   [arcminutes]
  final inner = h + (10.3 / (h + 5.11));
  final innerRad = inner * _rad;
  final tanv = math.tan(innerRad);
  if (tanv.abs() < 1e-6) return 34.0; // ~horizon limit
  return 1.02 / tanv;
}

Map<String, double> _sunAzAlt(DateTime dateTime, double latRad, double lonRad) {
  final utc = dateTime.isUtc ? dateTime : dateTime.toUtc();
  final jdUt = (utc.millisecondsSinceEpoch / _dayMs) + 2440587.5;

  final eph = _getSunEphemeris(jdUt);
  final dec = eph['declination_rad']!;
  final ra = eph['right_ascension_rad']!;
  final gastRad = eph['gmst_deg']! * _rad;
  final last = _normalizeAngleRad(gastRad + lonRad);

  double h = last - ra; // hour angle
  if (h > math.pi) h -= 2 * math.pi;
  if (h < -math.pi) h += 2 * math.pi;

  final sinHGeom = (math.sin(latRad) * math.sin(dec)) +
      (math.cos(latRad) * math.cos(dec) * math.cos(h));
  final hGeom = math.asin(sinHGeom.clamp(-1.0, 1.0)); // geometric altitude (rad)

  // Apply Bennett refraction near horizon (convert to apparent)
  double hDeg = hGeom * _deg;
  double refrArcmin = 0.0;
  if (hDeg > -1.0) {
    refrArcmin = _refractionArcminBennett(hDeg);
  }
  final refrRad = (refrArcmin / 60.0) * _rad;
  final hApp = (hGeom + refrRad).clamp(-math.pi / 2, math.pi / 2);

  // Azimuth from North, clockwise
  final y = -math.cos(dec) * math.sin(h);
  final x =  math.sin(dec) * math.cos(latRad) - math.cos(dec) * math.sin(latRad) * math.cos(h);
  final az = _normalizeAngleRad(math.atan2(y, x));

  return {'az': az, 'alt': hApp};
}

// ---------- Public API ----------
class SunUtils {
  static const double rad = _rad;
  static const double deg = _deg;

  // World constants
  static const double metersPerDegreeLat = 111320.0;
  static const double maxShadowLength = 1500.0;
  // Sun below this ≈ “night” for our shading purposes (sun center ~ -0.833° incl. refraction).
  static const double altitudeThresholdRad = -0.833 * rad;

  static const double defaultInsideBuildingCheckRadiusMeters = 0.1;

  /// Fast apparent Sun position (azimuth from North clockwise, altitude).
  static Map<String, double> getSunPosition(DateTime dateTime, double latDeg, double lngDeg) {
    final r = _sunAzAlt(dateTime, latDeg * rad, lngDeg * rad);
    return {'azimuth': r['az']!, 'altitude': r['alt']!};
  }

  // WebMercator meters-per-pixel at latitude & zoom (256px tiles basis).
  static double metersPerPixel(double latitudeDeg, double zoom) {
    // 156543.03392 m/px at equator, z=0.
    final cosLat = math.cos(latitudeDeg * rad).clamp(0.0, 1.0);
    return 156543.03392 * cosLat / math.pow(2.0, zoom);
  }

  static double metersPerDegreeLng(double latDeg) {
    return metersPerDegreeLat * math.cos(latDeg * rad);
  }
  static double metersToLng(double meters, double latDeg) {
    final mPerDeg = metersPerDegreeLng(latDeg);
    if (mPerDeg.abs() < 1e-7) return 0.0;
    return meters / mPerDeg;
  }
  static double metersToLat(double meters) => meters / metersPerDegreeLat;

  /// Is the place inside any shadow polygon (fast checks + polygons)?
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

    final effectiveR = (ignoreBuildingId != null) ? insideHostBuildingCheckRadiusMeters : checkRadiusMeters;

    final List<Position> pointsToCheck;
    if (effectiveR < 0.05) {
      pointsToCheck = [placePosition];
    } else {
      final dLat = SunUtils.metersToLat(effectiveR);
      final dLng = SunUtils.metersToLng(effectiveR, placeLat);
      pointsToCheck = [
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

    final sunDirX = math.sin(sunAzimuth_N_CW_rad); // +X east
    final sunDirY = math.cos(sunAzimuth_N_CW_rad); // +Y north

    for (final b in potentialBlockers) {
      if (b.id == ignoreBuildingId) continue;

      final cLat = (b.bounds.southwest.coordinates.lat + b.bounds.northeast.coordinates.lat) / 2.0;
      final cLng = (b.bounds.southwest.coordinates.lng + b.bounds.northeast.coordinates.lng) / 2.0;

      final dY = (cLat - placeLat) * metersPerDegreeLat;
      final dX = (cLng - placeLng) * metersPerDegreeLng(placeLat);
      final dist2 = dX * dX + dY * dY;
      if (dist2 > searchDistance * searchDistance) continue;

      // building should sit roughly *towards the Sun* from the place
      final dot = dX * sunDirX + dY * sunDirY;
      if (dot < 0) continue;

      final shadowPoly = buildingShadows[b.id];
      if (shadowPoly != null && shadowPoly.length >= 3) {
        for (final p in pointsToCheck) {
          if (SunUtils.isPointInPolygon(p, shadowPoly)) return true;
        }
      }
    }
    return false;
  }

  /// Project a building’s shadow polygon on ground.
  /// Pass a larger [minDrawableShadowMeters] to hide tiny, flickery shadows at high zoom/sun.
  static List<Position> calculateBuildingShadow({
    required Building building,
    required double sunAzimuth_N_CW_rad,
    required double sunAltitudeRad,
    double minDrawableShadowMeters = 0.5, // can be set per-zoom by caller
  }) {
    final poly = building.polygon;
    final h = math.max(0.1, building.height.toDouble());
    if (poly.length < 3 || sunAltitudeRad <= altitudeThresholdRad) return [];

    final tanAlt = math.tan(sunAltitudeRad);
    // Guard for ultra-small altitudes (near horizon).
    const minTan = 0.00175; // ~tan(0.1°)
    final t = tanAlt.abs() < minTan ? (tanAlt.isNegative ? -minTan : minTan) : tanAlt;

    // Physical shadow length
    final L = (h / t).abs();
    if (L < minDrawableShadowMeters) return [];            // visually negligible
    final clamped = L > maxShadowLength ? maxShadowLength : L;

    final dx = -clamped * math.sin(sunAzimuth_N_CW_rad); // meters east-west
    final dy = -clamped * math.cos(sunAzimuth_N_CW_rad); // meters north-south

    final shadowVerts = <Position>[];
    for (final v in poly) {
      final lat = v.lat.toDouble();
      final lng = v.lng.toDouble();
      final sLat = lat + metersToLat(dy);
      final sLng = lng + metersToLng(dx, lat);
      shadowVerts.add(Position(sLng, sLat));
    }

    final base = (poly.isNotEmpty &&
        poly.first.lat == poly.last.lat &&
        poly.first.lng == poly.last.lng)
        ? poly.sublist(0, poly.length - 1)
        : List<Position>.from(poly);

    if (base.length < 2) return [];

    final all = <Position>[...base, ...shadowVerts];
    final hull = _computeConvexHull(all);
    if (hull.length < 3) return [];
    if (hull.first.lat != hull.last.lat || hull.first.lng != hull.last.lng) {
      hull.add(hull.first);
    }
    return hull;
  }

  // ---------- Geometry helpers ----------
  static List<Position> _computeConvexHull(List<Position> pts) {
    if (pts.length <= 2) return List.from(pts);

    final seen = <String>{};
    final unique = pts.where((p) {
      final k = "${p.lat.toStringAsFixed(8)},${p.lng.toStringAsFixed(8)}";
      if (seen.contains(k)) return false;
      seen.add(k);
      return true;
    }).toList();
    if (unique.length <= 2) return List.from(unique);

    int start = 0;
    for (int i = 1; i < unique.length; i++) {
      if (unique[i].lat < unique[start].lat ||
          (unique[i].lat == unique[start].lat && unique[i].lng < unique[start].lng)) {
        start = i;
      }
    }

    final hull = <Position>[];
    int p = start;
    int q;
    final visited = <int>{};
    int iter = 0, maxIter = unique.length * 2 + 5;

    do {
      iter++;
      if ((visited.contains(p) && p != start) || iter > maxIter) {
        if (kDebugMode) {
          print("ConvexHull guard: loop or too many iterations (iter=$iter, n=${unique.length}).");
        }
        return hull.length >= 3 ? hull : [];
      }

      hull.add(unique[p]);
      visited.add(p);
      q = (p + 1) % unique.length;

      for (int r = 0; r < unique.length; r++) {
        if (r == p) continue;
        final cp = _cross(unique[p], unique[q], unique[r]);
        const eps = 1e-9;
        if (cp > eps) {
          q = r;
        } else if (cp.abs() < eps) {
          final dPQ = _dist2(unique[p], unique[q]);
          final dPR = _dist2(unique[p], unique[r]);
          if (dPR > dPQ) q = r;
        }
      }
      p = q;
    } while (p != start && iter <= maxIter);

    return hull;
  }

  static double _cross(Position p1, Position p2, Position p3) {
    final x1 = p1.lng.toDouble(), y1 = p1.lat.toDouble();
    final x2 = p2.lng.toDouble(), y2 = p2.lat.toDouble();
    final x3 = p3.lng.toDouble(), y3 = p3.lat.toDouble();
    return (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1);
  }

  static double _dist2(Position a, Position b) {
    final dx = a.lng.toDouble() - b.lng.toDouble();
    final dy = a.lat.toDouble() - b.lat.toDouble();
    return dx * dx + dy * dy;
  }

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
