import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../models/territory.dart';
import '../providers/auth_provider.dart';
import '../providers/territory_provider.dart';
import '../services/google_maps_config.dart';
import '../utils/format_utils.dart';
import '../utils/polygon_utils.dart';

/// Full-screen Google Maps bomb placement for the current user's territory.
/// The territory polygon is drawn on the map; tapping inside it places a bomb
/// at that lat/lng.  Tapping an existing bomb marker removes it.
class BombPlacementScreen extends StatefulWidget {
  final Territory territory;

  const BombPlacementScreen({super.key, required this.territory});

  @override
  State<BombPlacementScreen> createState() => _BombPlacementScreenState();
}

class _BombPlacementScreenState extends State<BombPlacementScreen> {
  late List<LatLng> _bombs;
  bool _isLoading = false;
  String? _feedback;
  bool _feedbackIsError = false;

  final Completer<gmaps.GoogleMapController> _mapCompleter = Completer();
  gmaps.GoogleMapController? _gMapController;
  bool _lastDarkMode = false;

  static const int _maxBombs = 3;

  @override
  void initState() {
    super.initState();
    _bombs = List<LatLng>.from(widget.territory.bombPositions);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isDark != _lastDarkMode && _gMapController != null) {
      _lastDarkMode = isDark;
      _gMapController!.setMapStyle(
        isDark ? GoogleMapsConfig.darkMapStyle : null,
      );
    }
  }

  @override
  void dispose() {
    _gMapController?.dispose();
    super.dispose();
  }

  // ── Geometry helpers ──────────────────────────────────────────────────────

  /// Arithmetic centroid of the territory polygon.
  LatLng _centroid() {
    final pts = widget.territory.polygon;
    if (pts.isEmpty) return const LatLng(22.5726, 88.3639);
    double lat = 0, lng = 0;
    for (final p in pts) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / pts.length, lng / pts.length);
  }

  /// Rough zoom level based on the bounding-box diagonal of the polygon.
  double _fitZoom() {
    final pts = widget.territory.polygon;
    if (pts.length < 2) return 16.0;
    double minLat = pts.first.latitude, maxLat = pts.first.latitude;
    double minLng = pts.first.longitude, maxLng = pts.first.longitude;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final span = (maxLat - minLat).abs() + (maxLng - minLng).abs();
    if (span < 0.001) return 18.0;
    if (span < 0.005) return 17.0;
    if (span < 0.01) return 16.0;
    if (span < 0.05) return 14.0;
    return 13.0;
  }

  /// Simple ray-casting point-in-polygon test on LatLng coordinates.
  bool _isInsidePolygon(LatLng point, List<LatLng> polygon) {
    if (polygon.length < 3) return false;
    bool inside = false;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      final pi = polygon[i];
      final pj = polygon[j];
      if (((pi.latitude > point.latitude) != (pj.latitude > point.latitude)) &&
          (point.longitude <
              (pj.longitude - pi.longitude) *
                      (point.latitude - pi.latitude) /
                      (pj.latitude - pi.latitude) +
                  pi.longitude)) {
        inside = !inside;
      }
      j = i;
    }
    return inside;
  }

  // ── API calls ─────────────────────────────────────────────────────────────

  Future<void> _placeBomb(LatLng pos) async {
    if (_isLoading) return;
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final tProv = Provider.of<TerritoryProvider>(context, listen: false);
    setState(() {
      _isLoading = true;
      _feedback = null;
    });
    try {
      final result = await auth.apiService.placeBomb(
        widget.territory.id,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      final newCount =
          (result['bombCount'] as num?)?.toInt() ?? (_bombs.length + 1);
      final rawPositions = result['bombPositions'] as List?;
      final newPositions = rawPositions != null
          ? rawPositions
                .map(
                  (p) => LatLng(
                    (p['lat'] as num).toDouble(),
                    (p['lng'] as num).toDouble(),
                  ),
                )
                .toList()
          : <LatLng>[..._bombs, pos];

      await auth.loadCurrentUser();
      tProv.updateTerritoryBombCount(
        widget.territory.id,
        newCount,
        newPositions: newPositions,
      );
      if (mounted) {
        setState(() {
          _bombs = newPositions;
          _isLoading = false;
          _feedback = '💣 Bomb armed at this position!';
          _feedbackIsError = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _feedback = e.toString().replaceFirst('Exception: ', '');
          _feedbackIsError = true;
        });
      }
    }
  }

  Future<void> _removeBomb(LatLng pos) async {
    if (_isLoading) return;
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final tProv = Provider.of<TerritoryProvider>(context, listen: false);
    setState(() {
      _isLoading = true;
      _feedback = null;
    });
    try {
      final result = await auth.apiService.removeBomb(
        widget.territory.id,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      final newCount =
          (result['bombCount'] as num?)?.toInt() ??
          math.max(0, _bombs.length - 1);
      final rawPositions = result['bombPositions'] as List?;
      final newPositions = rawPositions != null
          ? rawPositions
                .map(
                  (p) => LatLng(
                    (p['lat'] as num).toDouble(),
                    (p['lng'] as num).toDouble(),
                  ),
                )
                .toList()
          : _bombs.where((b) => b != pos).toList();

      await auth.loadCurrentUser();
      tProv.updateTerritoryBombCount(
        widget.territory.id,
        newCount,
        newPositions: newPositions,
      );
      if (mounted) {
        setState(() {
          _bombs = newPositions;
          _isLoading = false;
          _feedback = '↩️ Bomb returned to inventory.';
          _feedbackIsError = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _feedback = e.toString().replaceFirst('Exception: ', '');
          _feedbackIsError = true;
        });
      }
    }
  }

  // ── Map tap handler ───────────────────────────────────────────────────────

  void _onMapTap(gmaps.LatLng gLatLng) {
    final tapPoint = LatLng(gLatLng.latitude, gLatLng.longitude);

    // Check if inside the territory polygon
    if (!_isInsidePolygon(tapPoint, widget.territory.polygon)) {
      setState(() {
        _feedback = 'Tap inside your territory to place a bomb.';
        _feedbackIsError = false;
      });
      return;
    }

    final bombsInInventory =
        Provider.of<AuthProvider>(
          context,
          listen: false,
        ).currentUser?.bombInventory ??
        0;

    if (_bombs.length >= _maxBombs) {
      setState(() {
        _feedback = 'Max $_maxBombs bombs per territory. Remove one first.';
        _feedbackIsError = true;
      });
      return;
    }

    if (bombsInInventory < 1) {
      setState(() {
        _feedback = 'No bombs in inventory. Buy one from the Armory!';
        _feedbackIsError = true;
      });
      return;
    }

    _placeBomb(tapPoint);
  }

  /// Called when a bomb marker is tapped — removes that bomb.
  void _onBombMarkerTap(int bombIndex) {
    if (bombIndex < 0 || bombIndex >= _bombs.length) return;
    _removeBomb(_bombs[bombIndex]);
  }

  // ── Build Google Maps overlays ────────────────────────────────────────────

  Set<gmaps.Polygon> _buildPolygons() {
    final polygon = widget.territory.polygon;
    if (polygon.length < 3) return {};

    double sumLat = 0, sumLng = 0;
    for (final l in polygon) {
      sumLat += l.latitude;
      sumLng += l.longitude;
    }
    final cLat = sumLat / polygon.length;
    final cLng = sumLng / polygon.length;
    final cosLat = math.cos(cLat * math.pi / 180.0);

    // Local projection
    List<Offset> pts = polygon.map((l) {
      return Offset((l.longitude - cLng) * cosLat, l.latitude - cLat);
    }).toList();

    // Convex Hull and Smooth
    final hull = PolygonUtils.convexHull(pts);
    final smoothPts = PolygonUtils.smoothPolygon(hull, subdivisions: 14);

    // Convert back to LatLng
    final points = smoothPts.map((o) {
      return gmaps.LatLng(o.dy + cLat, (o.dx / cosLat) + cLng);
    }).toList();

    return {
      gmaps.Polygon(
        polygonId: const gmaps.PolygonId('territory'),
        points: points,
        fillColor: const Color(0xFF7C3AED).withOpacity(0.30),
        strokeColor: const Color(0xFFA78BFA),
        strokeWidth: 3,
        consumeTapEvents: false,
      ),
    };
  }

  Set<gmaps.Marker> _buildBombMarkers() {
    final markers = <gmaps.Marker>{};
    for (int i = 0; i < _bombs.length; i++) {
      final bomb = _bombs[i];
      markers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('bomb_$i'),
          position: gmaps.LatLng(bomb.latitude, bomb.longitude),
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
            gmaps.BitmapDescriptor.hueRed,
          ),
          infoWindow: gmaps.InfoWindow(
            title: '💣 Bomb #${i + 1}',
            snippet: 'Tap to remove',
          ),
          onTap: () => _onBombMarkerTap(i),
          zIndex: 3,
        ),
      );
    }
    return markers;
  }

  /// Blast radius = 20% of the territory's effective diameter.
  double _blastRadius() {
    final area = widget.territory.area; // square metres
    if (area <= 0) return 10;
    // effective diameter of a circle with the same area
    final diameter = 2 * math.sqrt(area / math.pi);
    return (diameter * 0.20).clamp(5.0, 200.0);
  }

  Set<gmaps.Circle> _buildBlastCircles() {
    final circles = <gmaps.Circle>{};
    final radius = _blastRadius();
    for (int i = 0; i < _bombs.length; i++) {
      final bomb = _bombs[i];
      circles.add(
        gmaps.Circle(
          circleId: gmaps.CircleId('blast_$i'),
          center: gmaps.LatLng(bomb.latitude, bomb.longitude),
          radius: radius,
          fillColor: const Color(0xFFEF4444).withOpacity(0.12),
          strokeColor: const Color(0xFFEF4444).withOpacity(0.35),
          strokeWidth: 1,
          zIndex: 2,
        ),
      );
    }
    return circles;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final territory = widget.territory;
    final center = _centroid();
    final zoom = _fitZoom();
    final isDark = theme.brightness == Brightness.dark;
    final auth = Provider.of<AuthProvider>(context);
    final bombsInInventory = auth.currentUser?.bombInventory ?? 0;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Stack(
        children: [
          // ── Google Map ────────────────────────────────────────────────────
          Positioned.fill(
            child: gmaps.GoogleMap(
              mapType: gmaps.MapType.normal,
              initialCameraPosition: gmaps.CameraPosition(
                target: gmaps.LatLng(center.latitude, center.longitude),
                zoom: zoom,
              ),
              onMapCreated: (controller) async {
                _gMapController = controller;
                if (!_mapCompleter.isCompleted) {
                  _mapCompleter.complete(controller);
                }
                _lastDarkMode = isDark;
                if (isDark) {
                  await controller.setMapStyle(GoogleMapsConfig.darkMapStyle);
                }
              },
              onTap: _onMapTap,
              polygons: _buildPolygons(),
              markers: _buildBombMarkers(),
              circles: _buildBlastCircles(),
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
            ),
          ),

          // ── Loading overlay ───────────────────────────────────────────────
          if (_isLoading)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.25),
                child: const Center(
                  child: CircularProgressIndicator(
                    color: Color(0xFF7C3AED),
                    strokeWidth: 2.5,
                  ),
                ),
              ),
            ),

          // ── Top bar (frosted-glass) — matches TerritoryMapScreen ──────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + 8,
                    bottom: 12,
                    left: 8,
                    right: 16,
                  ),
                  color: (isDark ? Colors.black : Colors.white).withOpacity(
                    0.72,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.arrow_back_ios_new_rounded,
                          color: theme.colorScheme.onSurface,
                          size: 20,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${territory.username}\'s Territory',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onSurface,
                              ),
                            ),
                            Text(
                              'Arm Defence',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme.colorScheme.onSurface.withOpacity(
                                  0.6,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Bomb count pill
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary.withOpacity(0.15),
                          border: Border.all(
                            color: theme.colorScheme.primary,
                            width: 1.5,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SvgPicture.asset(
                              'assets/explosive-bomb.svg',
                              width: 16,
                              height: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${_bombs.length}/$_maxBombs',
                              style: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Feedback banner (top, below app bar) ──────────────────────────
          if (_feedback != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 64,
              left: 16,
              right: 16,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: _feedbackIsError
                      ? Colors.red.withOpacity(0.92)
                      : Colors.green.withOpacity(0.92),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: (_feedbackIsError ? Colors.red : Colors.green)
                          .withOpacity(0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(
                      _feedbackIsError
                          ? Icons.error_outline_rounded
                          : Icons.check_circle_outline_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _feedback!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── Re-center FAB ──────────────────────────────────────────────────
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 260,
            right: 16,
            child: FloatingActionButton.small(
              onPressed: () => _gMapController?.animateCamera(
                gmaps.CameraUpdate.newCameraPosition(
                  gmaps.CameraPosition(
                    target: gmaps.LatLng(center.latitude, center.longitude),
                    zoom: zoom,
                  ),
                ),
              ),
              backgroundColor: theme.colorScheme.surface,
              foregroundColor: theme.colorScheme.onSurface,
              tooltip: 'Re-center',
              child: const Icon(Icons.my_location, size: 20),
            ),
          ),

          // ── Bottom info panel (frosted-glass) ──────────────────────────────
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 24,
            left: 16,
            right: 16,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  decoration: BoxDecoration(
                    color: (isDark ? Colors.grey[900]! : Colors.white)
                        .withOpacity(0.82),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: theme.dividerColor.withOpacity(0.5),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.12),
                        blurRadius: 20,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Drag handle
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurface.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Instruction row
                      Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: const Color(0xFF7C3AED).withOpacity(0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: SvgPicture.asset(
                                'assets/explosive-bomb.svg',
                                height: 28,
                                width: 28,
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Tap inside territory to place a bomb',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Tap a bomb marker to remove it',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: theme.colorScheme.onSurface
                                        .withOpacity(0.55),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Inventory pill
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: bombsInInventory > 0
                                  ? Colors.green.withOpacity(0.13)
                                  : Colors.red.withOpacity(0.13),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: bombsInInventory > 0
                                    ? Colors.green.withOpacity(0.3)
                                    : Colors.red.withOpacity(0.3),
                              ),
                            ),
                            child: Text(
                              '🎒 $bombsInInventory',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: bombsInInventory > 0
                                    ? Colors.green
                                    : Colors.red,
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),
                      Divider(
                        height: 1,
                        color: theme.dividerColor.withOpacity(0.4),
                      ),
                      const SizedBox(height: 12),

                      // Stats row
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _infoChip(
                            context,
                            Icons.shield_rounded,
                            'Placed',
                            '${_bombs.length}/$_maxBombs',
                          ),
                          _infoChip(
                            context,
                            Icons.border_all_rounded,
                            'Area',
                            formatArea(territory.area),
                          ),
                          _infoChip(
                            context,
                            Icons.person_rounded,
                            'Owner',
                            territory.username,
                          ),
                        ],
                      ),

                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoChip(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 15,
          color: theme.colorScheme.onSurface.withOpacity(0.5),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            color: theme.colorScheme.onSurface.withOpacity(0.5),
          ),
        ),
      ],
    );
  }
}
