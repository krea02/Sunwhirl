import 'dart:math' as math;
import 'package:flutter/foundation.dart'; // For kDebugMode
import 'package:intl/intl.dart';    // For debug printing dates
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart'; // Needed for Position

// Import your models (adjust paths if necessary)
import '../models/building.dart';
import '../models/place.dart';

// --- Astro Constants ---
// These constants are fundamental for solar position calculations.
// Many of these values and formulae are derived from common astronomical algorithms
// (e.g., approximations similar to those found in Jean Meeus' "Astronomical Algorithms" or the PSA algorithm).
const double _rad = math.pi / 180.0; // Conversion factor: degrees to radians
const double _deg = 180.0 / math.pi; // Conversion factor: radians to degrees
const double _dayMs = 1000 * 60 * 60 * 24.0; // Milliseconds in a day
const double _j2000 = 2451545.0; // Julian Day for Jan 1, 2000 12:00 UT (J2000.0 epoch)
// Mean Obliquity of the Ecliptic for J2000.0. The Earth's axial tilt.
const double _obliquityJ2000Rad = 23.4392911 * _rad;

// --- Helper Functions for Sun Position Calculation ---

/// Normalizes an angle to the range [0, 360) degrees.
double _normalizeAngleDeg(double angleDeg) {
  double b = angleDeg / 360.0;
  double normalized = (b - b.floor()) * 360.0;
  return normalized < 0 ? normalized + 360.0 : normalized;
}

/// Normalizes an angle to the range [0, 2*pi) radians.
double _normalizeAngleRad(double angleRad) {
  double twoPi = 2 * math.pi;
  double normalized = angleRad % twoPi;
  return normalized < 0 ? normalized + twoPi : normalized;
}

/// Calculates key ephemeris data for the Sun.
/// [jdUt] Julian Day in Universal Time.
/// Returns a map containing:
///   'declination_rad': Sun's declination in radians.
///   'right_ascension_rad': Sun's right ascension in radians.
///   'gmst_deg': Greenwich Mean Sidereal Time in degrees.
/// The formulae used are approximations for heliocentric longitude, latitude, and distance.
Map<String, double> _getSunEphemeris(double jdUt) {
  // Time `dJ2000` is days since J2000.0 epoch.
  // Time `tJc` is Julian centuries since J2000.0 epoch.
  double dJ2000 = jdUt - _j2000;
  double tJc = dJ2000 / 36525.0;

  // Mean Longitude of the Sun, corrected for aberration.
  double lSunMeanDeg = _normalizeAngleDeg(280.46646 + 36000.76983 * tJc + 0.0003032 * tJc * tJc);
  // Mean Anomaly of the Sun.
  double mSunMeanDeg = _normalizeAngleDeg(357.52911 + 35999.05029 * tJc - 0.0001537 * tJc * tJc);
  double mSunMeanRad = mSunMeanDeg * _rad;

  // Equation of Center for the Sun.
  double cSunDeg = (1.914602 - 0.004817 * tJc - 0.000014 * tJc * tJc) * math.sin(mSunMeanRad) +
      (0.019993 - 0.000101 * tJc) * math.sin(2 * mSunMeanRad) +
      0.000289 * math.sin(3 * mSunMeanRad);

  // True Longitude of the Sun.
  double lambdaSunTrueDeg = _normalizeAngleDeg(lSunMeanDeg + cSunDeg);
  double lambdaSunTrueRad = lambdaSunTrueDeg * _rad;
  // Obliquity of the Ecliptic (using J2000.0 mean value, a simplification).
  double epsilonRad = _obliquityJ2000Rad;

  // Right Ascension (alpha) of the Sun.
  double alphaSunRad = math.atan2(math.cos(epsilonRad) * math.sin(lambdaSunTrueRad), math.cos(lambdaSunTrueRad));
  alphaSunRad = _normalizeAngleRad(alphaSunRad); // Ensure [0, 2*pi)

  // Declination (delta) of the Sun.
  double deltaSunRad = math.asin(math.sin(epsilonRad) * math.sin(lambdaSunTrueRad));

  // Greenwich Mean Sidereal Time (GMST).
  // Formula from Astronomical Almanac, or similar sources (e.g., Meeus).
  double gmstDeg = _normalizeAngleDeg(280.46061837 + 360.985647366289 * dJ2000 + 0.000387933*tJc*tJc - tJc*tJc*tJc/38710000.0);

  return {
    'declination_rad': deltaSunRad,
    'right_ascension_rad': alphaSunRad,
    'gmst_deg': gmstDeg,
  };
}

/// Internal function to calculate Sun's apparent position (azimuth and altitude).
/// [dateTime] The date and time for the calculation.
/// [latRad] Latitude of the observer in radians.
/// [lonRad] Longitude of the observer in radians.
/// Returns a map with 'azimuth_N_CW_rad' (from North, clockwise) and 'altitude_rad'.
Map<String, double> _calculateSunPositionInternal(DateTime dateTime, double latRad, double lonRad) {
  // Ensure UTC for calculations.
  final DateTime utcDate = dateTime.isUtc ? dateTime : dateTime.toUtc();
  // Convert UTC DateTime to Julian Day.
  // 2440587.5 is JD for 1970-01-01 00:00:00 UTC (Unix epoch).
  final double jdUt = (utcDate.millisecondsSinceEpoch / _dayMs) + 2440587.5;

  Map<String, double> sunEphem = _getSunEphemeris(jdUt);
  double decRad = sunEphem['declination_rad']!;
  double raRad = sunEphem['right_ascension_rad']!;
  double gmstDeg = sunEphem['gmst_deg']!;

  // Greenwich Apparent Sidereal Time (GAST) approx GMST for this purpose.
  double gastRad = gmstDeg * _rad;
  // Local Apparent Sidereal Time (LAST).
  double lastRad = _normalizeAngleRad(gastRad + lonRad);

  // Hour Angle (H).
  double hRad = lastRad - raRad;
  // Normalize Hour Angle to [-pi, pi) for trigonometric functions.
  if (hRad > math.pi) hRad -= (2 * math.pi);
  if (hRad < -math.pi) hRad += (2 * math.pi);

  // Geometric Altitude (h_geom).
  // sin(h_geom) = sin(lat)*sin(dec) + cos(lat)*cos(dec)*cos(H)
  double sinHGeom = math.sin(latRad) * math.sin(decRad) + math.cos(latRad) * math.cos(decRad) * math.cos(hRad);
  sinHGeom = sinHGeom.clamp(-1.0, 1.0); // Ensure valid input for asin.
  double hGeomRad = math.asin(sinHGeom);

  // Atmospheric Refraction Correction.
  // This is an empirical formula (e.g., Bennett's formula or similar).
  // Refraction makes objects appear higher than they are, especially near the horizon.
  double refractionRad;
  if (hGeomRad * _deg > -1.2) { // Only apply refraction if sun is not too far below horizon.
    // Clamp geometric altitude for refraction calculation to avoid extreme values.
    double hGeomForRefrDeg = (hGeomRad * _deg).clamp(-1.0, 89.0);
    // Denominator of Bennett's formula argument.
    double bennettArgDenominator = hGeomForRefrDeg + 4.4;
    if (bennettArgDenominator.abs() < 1e-6) bennettArgDenominator = 1e-6; // Avoid division by zero.

    double angleForCotArgDeg = hGeomForRefrDeg + (7.31 / bennettArgDenominator);
    double angleForCotArgRad = angleForCotArgDeg * _rad;

    // Handle cases where cotangent might be undefined or very large.
    if (math.sin(angleForCotArgRad).abs() < 1e-9) { // Near poles of cotangent
      refractionRad = (34.0 / 60.0) * _rad; // Standard refraction at horizon (approx)
    } else {
      double tanVal = math.tan(angleForCotArgRad);
      if (tanVal.abs() < 1e-9) { // If tan is near zero, cot is very large.
        refractionRad = (34.0 / 60.0) * _rad; // Should use a limit or a different model here.
      } else {
        double refrArcmin = 1.0 / tanVal; // Refraction in arcminutes.
        refractionRad = (refrArcmin / 60.0) * _rad; // Convert to radians.
      }
    }
    refractionRad = math.max(0, refractionRad); // Refraction always lifts the object.
  } else {
    refractionRad = 0.0; // No refraction effect calculated if too far below horizon.
  }

  // Apparent Altitude (h_apparent) = Geometric Altitude + Refraction.
  double hApparentRad = hGeomRad + refractionRad;
  hApparentRad = hApparentRad.clamp(-math.pi / 2.0, math.pi / 2.0); // Clamp to valid altitude range.

  // Azimuth (Az_N_CW), measured clockwise from North.
  // Y component for atan2: -cos(dec)*sin(H)
  // X component for atan2: sin(dec)*cos(lat) - cos(dec)*sin(lat)*cos(H)
  double azNCwYComponent = -math.cos(decRad) * math.sin(hRad);
  double azNCwXComponent = math.sin(decRad) * math.cos(latRad) - math.cos(decRad) * math.sin(latRad) * math.cos(hRad);
  double azNCwRad = math.atan2(azNCwYComponent, azNCwXComponent);
  azNCwRad = _normalizeAngleRad(azNCwRad); // Ensure [0, 2*pi)

  // --- DEBUG LOGGING ---
  // ** IMPORTANT: UNCOMMENT THIS BLOCK FOR TESTING **
  /*
  if (kDebugMode) {
    final df = DateFormat("yyyy-MM-dd HH:mm:ss 'UTC'");
    double dJ2000Log = jdUt - _j2000;
    double tJcLog = dJ2000Log / 36525.0;
    double lSunMeanDegLog = _normalizeAngleDeg(280.46646 + 36000.76983 * tJcLog + 0.0003032 * tJcLog * tJcLog);
    double mSunMeanDegLog = _normalizeAngleDeg(357.52911 + 35999.05029 * tJcLog - 0.0001537 * tJcLog * tJcLog);

    print("--- FULL SUN DEBUG ---");
    print("Time: ${df.format(utcDate)}, Lat: ${latRad * _deg}°, Lon: ${lonRad * _deg}°");
    print("JD_UT: $jdUt, d_j2000: $dJ2000Log, t_jc: $tJcLog");
    print("L_sun_mean_deg: $lSunMeanDegLog, M_sun_mean_deg: $mSunMeanDegLog");
    print("Declination_rad: $decRad (${decRad*_deg}°)");
    print("RightAscension_rad: $raRad (${raRad*_deg / 15.0}h)");
    print("GMST_deg: $gmstDeg, LAST_rad: $lastRad (${lastRad*_deg/15.0}h)");
    print("HourAngle_rad: $hRad (${hRad*_deg}°)");
    print("sin(h_geom): $sinHGeom, Geom Alt_rad: $hGeomRad (${hGeomRad*_deg}°)");
    print("Refraction_rad: $refractionRad (${refractionRad*_deg}°)");
    print("APPARENT ALTITUDE_rad: $hApparentRad (${hApparentRad*_deg}°)");
    print("AZIMUTH_N_CW_rad: $azNCwRad (${azNCwRad*_deg}° from North CW)");
    print("--- END FULL SUN DEBUG ---");
  }
  */

  return {'azimuth_N_CW_rad': azNCwRad, 'altitude_rad': hApparentRad};
}

class SunUtils {
  static const double rad = _rad;
  static const double deg = _deg;

  // Average Earth radius related constants for distance calculations.
  static const double metersPerDegreeLat = 111320.0; // Approx. meters per degree of latitude.
  // Maximum shadow length to compute/draw, prevents extremely long shadows at sunrise/sunset.
  static const double maxShadowLength = 1500.0;
  // Sun altitude threshold (degrees) below which it's considered "night" or sun below horizon for shadow purposes.
  // -0.833 degrees is a common value for sunrise/sunset (center of sun disk on horizon considering refraction).
  static const double altitudeThresholdRad = -0.833 * rad;

  static const double defaultInsideBuildingCheckRadiusMeters = 0.1;

  /// Public method to get Sun's Azimuth (from North, clockwise) and Altitude.
  /// [dateTime] The date and time for the calculation.
  /// [lat] Latitude of the observer in degrees.
  /// [lng] Longitude of the observer in degrees.
  /// Returns a map with 'altitude' and 'azimuth' in radians.
  static Map<String, double> getSunPosition(DateTime dateTime, double lat, double lng) {
    final Map<String, double> sunPos = _calculateSunPositionInternal(
        dateTime, lat * rad, lng * rad // Convert degrees to radians for internal calculation
    );
    return {
      'altitude': sunPos['altitude_rad']!, // Apparent altitude
      'azimuth': sunPos['azimuth_N_CW_rad']!  // Azimuth from North, clockwise
    };
  }

  /// Calculates approximate meters per degree of longitude at a given latitude.
  static double metersPerDegreeLng(double latDeg) {
    return metersPerDegreeLat * math.cos(latDeg * rad);
  }

  /// Converts meters to degrees of longitude at a given latitude.
  static double metersToLng(double meters, double latDeg) {
    double mPerDeg = metersPerDegreeLng(latDeg);
    if (mPerDeg.abs() < 1e-7) return 0.0; // Avoid division by zero at poles.
    return meters / mPerDeg;
  }

  /// Converts meters to degrees of latitude.
  static double metersToLat(double meters) {
    return meters / metersPerDegreeLat;
  }

  /// Checks if a given place is in shadow.
  static bool isPlaceInShadow({
    required Position placePosition,
    required double sunAzimuth_N_CW_rad,
    required double sunAltitudeRad,
    required List<Building> potentialBlockers,
    required Map<String, List<Position>> buildingShadows, // Pre-calculated shadow polygons
    String? ignoreBuildingId, // To ignore the building the place might be part of
    double searchDistance = maxShadowLength + 100.0, // How far to check for blockers
    double checkRadiusMeters = 1.25, // Radius around the place to check for shadow
    double insideHostBuildingCheckRadiusMeters = defaultInsideBuildingCheckRadiusMeters,
  }) {
    final placeLat = placePosition.lat.toDouble();
    final placeLng = placePosition.lng.toDouble();

    // If sun is below horizon threshold, everything is in "shadow" (night).
    if (sunAltitudeRad <= altitudeThresholdRad) return true;
    if (potentialBlockers.isEmpty) return false; // No buildings, no shadow.

    final double effectiveCheckRadius = (ignoreBuildingId != null)
        ? insideHostBuildingCheckRadiusMeters // Smaller radius if checking inside its own building
        : checkRadiusMeters;

    // Define points to check around the place (center + cardinal/diagonal points if radius is significant).
    final List<Position> pointsToCheck;
    if (effectiveCheckRadius < 0.05) { // If radius is very small, only check center point
      pointsToCheck = [placePosition];
    } else {
      final double latOffset = SunUtils.metersToLat(effectiveCheckRadius);
      final double lngOffset = SunUtils.metersToLng(effectiveCheckRadius, placeLat);
      pointsToCheck = [
        placePosition, // Center
        Position(placeLng, placeLat + latOffset), // North
        Position(placeLng, placeLat - latOffset), // South
        Position(placeLng + lngOffset, placeLat), // East
        Position(placeLng - lngOffset, placeLat), // West
        Position(placeLng + lngOffset, placeLat + latOffset), // NE
        Position(placeLng - lngOffset, placeLat + latOffset), // NW
        Position(placeLng + lngOffset, placeLat - latOffset), // SE
        Position(placeLng - lngOffset, placeLat - latOffset), // SW
      ];
    }

    for (final building in potentialBlockers) {
      if (building.id == ignoreBuildingId) continue; // Don't check against host building if specified

      // --- Basic culling based on distance and direction ---
      final buildingCenterLat = (building.bounds.southwest.coordinates.lat + building.bounds.northeast.coordinates.lat) / 2.0;
      final buildingCenterLng = (building.bounds.southwest.coordinates.lng + building.bounds.northeast.coordinates.lng) / 2.0;
      final double metersToBuildingLat = (buildingCenterLat - placeLat) * metersPerDegreeLat;
      final double metersToBuildingLng = (buildingCenterLng - placeLng) * metersPerDegreeLng(placeLat);
      final double distSqToBuilding = metersToBuildingLat * metersToBuildingLat + metersToBuildingLng * metersToBuildingLng;

      // If building is too far, it can't cast a shadow on the place.
      if (distSqToBuilding > searchDistance * searchDistance) continue;

      // Quick check: if building is generally in the opposite direction of the sun, it can't block.
      final double sunDirX = math.sin(sunAzimuth_N_CW_rad); // Eastward component
      final double sunDirY = math.cos(sunAzimuth_N_CW_rad); // Northward component
      // Dot product: > 0 if building is generally in the same direction as the sun from the place.
      final double dotProduct = metersToBuildingLng * sunDirX + metersToBuildingLat * sunDirY;
      if (dotProduct < 0) continue; // Building is "behind" the place relative to sun direction.

      // Use pre-calculated shadow polygon for the building.
      final shadowPolygon = buildingShadows[building.id];
      if (shadowPolygon != null && shadowPolygon.length >= 3) {
        for (final point in pointsToCheck) {
          if (SunUtils.isPointInPolygon(point, shadowPolygon)) {
            return true; // At least one check point is in this building's shadow.
          }
        }
      }
    }
    return false; // No shadow found from any potential blocker.
  }

  /// Estimates the minimum sun altitude required for sunlight to clear a building of a certain height at a certain distance.
  static double estimateMinimumSunAltitudeToClearBuildings({
    required double buildingHeightMeters,
    required double distanceMeters,
  }) {
    if (distanceMeters <= 1e-3) return math.pi / 2.0; // If at building, needs sun directly overhead.
    return math.atan(buildingHeightMeters / distanceMeters);
  }

  /// Calculates the 2D ground projection of a building's shadow.
  static List<Position> calculateBuildingShadow({
    required Building building,
    required double sunAzimuth_N_CW_rad,
    required double sunAltitudeRad,
  }) {
    final polygon = building.polygon; // Building footprint
    final height = math.max(0.1, building.height.toDouble()); // Ensure positive height

    // If sun is below horizon or building footprint is invalid, no shadow.
    if (polygon.length < 3 || sunAltitudeRad <= altitudeThresholdRad) return [];

    final tanAltitude = math.tan(sunAltitudeRad);
    // Minimum effective tan(altitude) to prevent division by zero or extremely large shadows if sun is at horizon.
    // tan(0.1 deg) approx 0.0017. Using a slightly larger value for stability.
    const minTanAltitude = 0.00175; // tan(0.1 deg) is approx 0.001745
    final effectiveTanAltitude = math.max(minTanAltitude, tanAltitude);

    // If effectiveTanAltitude is extremely small (sun very low but above threshold), shadow can be huge.
    // This check might be redundant if altitudeThresholdRad is effective.
    if (effectiveTanAltitude.abs() < 1e-9) return []; // Should be caught by altitudeThresholdRad or minTanAltitude

    // Shadow length = height / tan(altitude).
    final shadowLength = height / effectiveTanAltitude;

    // Clamp shadow length to a maximum practical value.
    final clampedLength = shadowLength.abs() > maxShadowLength
        ? maxShadowLength * shadowLength.sign // Apply sign if original shadowLength was negative (sun below tan(0))
        : shadowLength;

    // Minimum shadow length to draw. Avoids tiny, negligible shadows.
    // This is key for "no shadows at high noon": if shadow is <0.5m, it won't be drawn.
    const double minDrawableShadowExtension = 0.5; // meters
    if (clampedLength.abs() < minDrawableShadowExtension) return [];

    // Shadow displacement vector components.
    // Shadow is cast in the opposite direction of the sun's azimuth.
    // Azimuth is N_CW, so +sin(az) is East, +cos(az) is North.
    // Shadow dx is -length * sin(azimuth), dy is -length * cos(azimuth).
    final dx = -clampedLength * math.sin(sunAzimuth_N_CW_rad); // Displacement in longitude (meters)
    final dy = -clampedLength * math.cos(sunAzimuth_N_CW_rad); // Displacement in latitude (meters)

    // Create shadow vertices by displacing footprint vertices.
    final shadowVertices = <Position>[];
    for (final vertex in polygon) {
      final lat = vertex.lat.toDouble();
      final lng = vertex.lng.toDouble();
      final shadowLat = lat + metersToLat(dy); // Convert dy (meters) to latitude offset
      final shadowLng = lng + metersToLng(dx, lat); // Convert dx (meters) to longitude offset
      shadowVertices.add(Position(shadowLng, shadowLat));
    }

    // Prepare points for convex hull: original footprint vertices + shadow projection vertices.
    // Ensure base points don't have the closing duplicate if present.
    final List<Position> basePoints = polygon.isNotEmpty &&
        polygon.first.lat == polygon.last.lat &&
        polygon.first.lng == polygon.last.lng
        ? polygon.sublist(0, polygon.length - 1)
        : List.from(polygon);

    if (basePoints.length < 2) return []; // Not enough points for a meaningful hull

    final allPoints = <Position>[...basePoints, ...shadowVertices];
    List<Position> hullPoints = _computeConvexHull(allPoints);

    // Ensure the hull is a closed polygon for drawing.
    if (hullPoints.length >= 3 &&
        (hullPoints.first.lat != hullPoints.last.lat ||
            hullPoints.first.lng != hullPoints.last.lng)) {
      hullPoints.add(hullPoints.first); // Close the polygon
    } else if (hullPoints.length < 3) {
      return []; // Not a valid polygon
    }
    return hullPoints;
  }

  /// Computes the convex hull of a set of 2D points using the Jarvis March (Gift Wrapping) algorithm.
  static List<Position> _computeConvexHull(List<Position> points) {
    if (points.length <= 2) return List.from(points); // Hull is the points themselves or a line

    // Remove duplicate points to avoid issues with collinearity checks and performance.
    final Set<String> uniqueKeys = {};
    final List<Position> uniquePointList = points.where((p) {
      // Precision for uniqueness check.
      final key = "${p.lat.toStringAsFixed(8)},${p.lng.toStringAsFixed(8)}";
      if (uniqueKeys.contains(key)) return false;
      uniqueKeys.add(key);
      return true;
    }).toList();

    if (uniquePointList.length <= 2) return List.from(uniquePointList);

    List<Position> hull = [];

    // Find the starting point: the one with the smallest y-coordinate (latitude).
    // If ties, pick the one with the smallest x-coordinate (longitude).
    int startPointIndex = 0;
    for (int i = 1; i < uniquePointList.length; i++) {
      if (uniquePointList[i].lat < uniquePointList[startPointIndex].lat) {
        startPointIndex = i;
      } else if (uniquePointList[i].lat == uniquePointList[startPointIndex].lat &&
          uniquePointList[i].lng < uniquePointList[startPointIndex].lng) {
        startPointIndex = i;
      }
    }

    int currentPointIndex = startPointIndex;
    int nextPointIndex = -1;
    final Set<int> hullIndices = {}; // To detect loops in rare degenerate cases
    int iteration = 0;
    // Max iterations as a safeguard against infinite loops (should not happen with proper unique points).
    final int maxIterations = uniquePointList.length * 2 + 5; // Increased slightly

    do {
      iteration++; // Ensure iteration count always advances
      // Safeguard: if we are re-adding a point (other than start) or exceed iterations.
      if ((hullIndices.contains(currentPointIndex) && currentPointIndex != startPointIndex) ||
          iteration > maxIterations) {
        if (kDebugMode) {
          print("Convex Hull Error: Loop detected or exceeded max iterations ($iteration > $maxIterations). Aborting. Hull size: ${hull.length}, Input size: ${uniquePointList.length}");
        }
        // Return what we have if it's somewhat valid, or empty if too small.
        return hull.length >= 3 ? hull : [];
      }

      hull.add(uniquePointList[currentPointIndex]);
      hullIndices.add(currentPointIndex);

      // Find the next point in the hull.
      nextPointIndex = (currentPointIndex + 1) % uniquePointList.length;
      for (int candidateIndex = 0; candidateIndex < uniquePointList.length; candidateIndex++) {
        if (candidateIndex == currentPointIndex) continue; // Skip self

        // Cross product determines orientation.
        // (p2 - p1) x (p3 - p1)
        // Positive: p3 is to the left of vector p1->p2 (counter-clockwise turn).
        // Negative: p3 is to the right.
        // Zero: p1, p2, p3 are collinear.
        final double crossProduct = _crossProduct(uniquePointList[currentPointIndex], uniquePointList[nextPointIndex], uniquePointList[candidateIndex]);

        const epsilon = 1e-9; // Tolerance for floating point comparisons.

        if (crossProduct > epsilon) { // candidateIndex is to the left of current_point -> next_point vector
          nextPointIndex = candidateIndex;
        } else if (crossProduct.abs() < epsilon) {
          // Collinear case: pick the farthest point.
          final double distSqCurrentNext = _distSq(uniquePointList[currentPointIndex], uniquePointList[nextPointIndex]);
          final double distSqCurrentCandidate = _distSq(uniquePointList[currentPointIndex], uniquePointList[candidateIndex]);
          if (distSqCurrentCandidate > distSqCurrentNext) {
            nextPointIndex = candidateIndex;
          }
        }
      }
      currentPointIndex = nextPointIndex;
    } while (currentPointIndex != startPointIndex && iteration <= maxIterations); // Loop until back to start.

    return hull;
  }

  /// Calculates the 2D cross product of vectors (p1->p2) and (p1->p3).
  /// Used to determine turn direction (left, right, or collinear).
  static double _crossProduct(Position p1, Position p2, Position p3) {
    final double p1lng = p1.lng.toDouble(); final double p1lat = p1.lat.toDouble();
    final double p2lng = p2.lng.toDouble(); final double p2lat = p2.lat.toDouble();
    final double p3lng = p3.lng.toDouble(); final double p3lat = p3.lat.toDouble();
    // (x2 - x1)(y3 - y1) - (y2 - y1)(x3 - x1)
    return (p2lng - p1lng) * (p3lat - p1lat) - (p2lat - p1lat) * (p3lng - p1lng);
  }

  /// Calculates the squared Euclidean distance between two points.
  /// Used for comparing distances (avoids sqrt).
  static double _distSq(Position p1, Position p2) {
    final double dx = p1.lng.toDouble() - p2.lng.toDouble();
    final double dy = p1.lat.toDouble() - p2.lat.toDouble();
    return dx * dx + dy * dy;
  }

  /// Checks if a point is inside a polygon using the Ray Casting algorithm.
  static bool isPointInPolygon(Position point, List<Position> polygon) {
    if (polygon.length < 3) return false; // Not a valid polygon.

    bool isInside = false;
    final double x = point.lng.toDouble(); // Point's longitude
    final double y = point.lat.toDouble(); // Point's latitude
    const double epsilon = 1e-9; // Tolerance for floating point comparisons

    // Iterate through polygon edges (p_i, p_j).
    for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
      final double xi = polygon[i].lng.toDouble(); final double yi = polygon[i].lat.toDouble();
      final double xj = polygon[j].lng.toDouble(); final double yj = polygon[j].lat.toDouble();

      // Check if the ray (y = point.lat) intersects the edge (yi, yj).
      // Edge must cross the horizontal ray.
      final bool intersectCondition = ((yi > y) != (yj > y));
      if (!intersectCondition) continue;

      // Calculate the x-coordinate of the intersection point of the ray and the edge.
      final double edgeDy = yj - yi;

      // Handle horizontal edges or point on vertex carefully.
      if (edgeDy.abs() < epsilon) { // Edge is (almost) horizontal
        if ((y - yi).abs() < epsilon) { // Point is on the same latitude as horizontal edge
          // Check if point is within the x-range of the horizontal edge
          if (x >= math.min(xi, xj) - epsilon && x <= math.max(xi, xj) + epsilon) return true; // Point on edge
        }
        continue; // Horizontal edge not crossing or point not on it.
      }

      // Intersection x-coordinate
      final double intersectX = (xj - xi) * (y - yi) / edgeDy + xi;

      // If point is on the edge segment (collinear and within bounds)
      if ((x - intersectX).abs() < epsilon) return true; // Point is on the boundary

      // If intersection is to the right of the point, toggle 'isInside'.
      if (x < intersectX) {
        isInside = !isInside;
      }
    }
    return isInside;
  }

  /// Generates an icon path string based on place type and sun status.
  static String getIconPath(PlaceType type, bool isInSun) {
    final String base = switch (type) {
      PlaceType.cafe => "cafe",
      PlaceType.pub => "pub",
      PlaceType.park => "park",
      _ => "default", // Fallback for other types
    };
    final String condition = isInSun ? "sun" : "moon"; // Or "shade", "night"
    return "${base}_$condition"; // e.g., "cafe_sun", "park_moon"
  }
}