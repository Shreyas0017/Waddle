// Utility function to calculate polygon area using Shoelace formula
const calculatePolygonArea = (polygon) => {
  console.log('📐 Calculating area for polygon with', polygon.length, 'points');
  console.log('📍 First point:', polygon[0]);
  console.log('📍 Last point:', polygon[polygon.length - 1]);
  
  if (polygon.length < 3) {
    console.log('❌ Not enough points for area calculation');
    return 0;
  }

  // Validate coordinates
  for (let i = 0; i < polygon.length; i++) {
    if (!polygon[i].lat || !polygon[i].lng) {
      console.log(`❌ Invalid coordinates at index ${i}:`, polygon[i]);
      return 0;
    }
    if (isNaN(polygon[i].lat) || isNaN(polygon[i].lng)) {
      console.log(`❌ NaN coordinates at index ${i}:`, polygon[i]);
      return 0;
    }
  }

  let area = 0;
  for (let i = 0; i < polygon.length; i++) {
    const j = (i + 1) % polygon.length;
    area += polygon[i].lng * polygon[j].lat;
    area -= polygon[j].lng * polygon[i].lat;
  }
  
  area = Math.abs(area) / 2;
  console.log('📏 Raw area (degrees²):', area);
  
  // Convert to square meters (approximate)
  const avgLat = polygon.reduce((sum, p) => sum + p.lat, 0) / polygon.length;
  const metersPerDegreeLat = 111320;
  const metersPerDegreeLon = 111320 * Math.cos(avgLat * Math.PI / 180);
  
  const finalArea = area * metersPerDegreeLat * metersPerDegreeLon;
  console.log('📐 Converted area (m²):', finalArea.toFixed(2));
  console.log('📍 Average latitude:', avgLat);
  console.log('📏 Meters per degree: lat=', metersPerDegreeLat, 'lon=', metersPerDegreeLon.toFixed(2));
  
  return finalArea;
};

// Calculate distance between two points
const calculateDistance = (path) => {
  if (path.length < 2) return 0;

  let totalDistance = 0;
  for (let i = 0; i < path.length - 1; i++) {
    const lat1 = path[i].lat;
    const lon1 = path[i].lng;
    const lat2 = path[i + 1].lat;
    const lon2 = path[i + 1].lng;

    const R = 6371e3; // Earth's radius in meters
    const φ1 = lat1 * Math.PI / 180;
    const φ2 = lat2 * Math.PI / 180;
    const Δφ = (lat2 - lat1) * Math.PI / 180;
    const Δλ = (lon2 - lon1) * Math.PI / 180;

    const a = Math.sin(Δφ / 2) * Math.sin(Δφ / 2) +
              Math.cos(φ1) * Math.cos(φ2) *
              Math.sin(Δλ / 2) * Math.sin(Δλ / 2);
    const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

    totalDistance += R * c;
  }
  return totalDistance;
};

// Check if path forms a closed loop - more lenient threshold
const isClosedLoop = (path, thresholdMeters = 100) => {
  if (path.length < 3) return false;

  const start = path[0];
  const end = path[path.length - 1];

  const R = 6371e3;
  const φ1 = start.lat * Math.PI / 180;
  const φ2 = end.lat * Math.PI / 180;
  const Δφ = (end.lat - start.lat) * Math.PI / 180;
  const Δλ = (end.lng - start.lng) * Math.PI / 180;

  const a = Math.sin(Δφ / 2) * Math.sin(Δφ / 2) +
            Math.cos(φ1) * Math.cos(φ2) *
            Math.sin(Δλ / 2) * Math.sin(Δλ / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  const distance = R * c;

  console.log(`Loop check: distance between start and end = ${distance.toFixed(2)}m (threshold: ${thresholdMeters}m)`);
  return distance <= thresholdMeters;
};

// Haversine distance between two points (meters)
const pointDistance = (p1, p2) => {
  const R = 6371e3;
  const φ1 = p1.lat * Math.PI / 180;
  const φ2 = p2.lat * Math.PI / 180;
  const Δφ = (p2.lat - p1.lat) * Math.PI / 180;
  const Δλ = (p2.lng - p1.lng) * Math.PI / 180;
  const a = Math.sin(Δφ/2) * Math.sin(Δφ/2) +
            Math.cos(φ1) * Math.cos(φ2) *
            Math.sin(Δλ/2) * Math.sin(Δλ/2);
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
};

// Remove GPS outlier points — consecutive points with >50m gap are impossible
// for walking-speed GPS updates (distanceFilter 3m, so 50m is extremely generous)
const sanitizePath = (path) => {
  if (!path || path.length < 2) return path || [];

  const clean = [path[0]];
  for (let i = 1; i < path.length; i++) {
    const d = pointDistance(clean[clean.length - 1], path[i]);
    if (d <= 50) {
      clean.push(path[i]);
    } else {
      console.log(`🧹 Backend: stripped outlier #${i}: ${d.toFixed(0)}m jump`);
    }
  }

  return clean;
};

module.exports = {
  calculatePolygonArea,
  calculateDistance,
  isClosedLoop,
  sanitizePath,
  pointDistance,
};
