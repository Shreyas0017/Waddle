import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart' hide Path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import '../providers/auth_provider.dart';
import '../providers/activity_provider.dart';
import '../providers/territory_provider.dart';
import '../providers/theme_provider.dart';
import '../models/territory.dart';
import '../services/location_service.dart';
import '../services/google_maps_config.dart';
import '../utils/format_utils.dart';
import '../widgets/compass_widget.dart';
import '../widgets/kingdom_territory_layer.dart';
import '../widgets/territory_stats_sheet.dart';
import '../utils/kingdom_native_map_generator.dart';
import '../utils/territory_colors.dart';
import '../utils/smooth_location.dart';
import '../widgets/topaz_reward_modal.dart';
import 'profile_screen.dart';
import 'leaderboard_screen.dart';
import 'events_screen.dart';
import 'health_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // Google Maps controller (resolved once the map widget is ready)
  final Completer<gmaps.GoogleMapController> _mapCompleter = Completer();
  gmaps.GoogleMapController? _gMapController;
  bool _lastDarkMode = false; // track dark mode for reactive style changes
  // Camera position notifier for the territory overlay (avoids parent rebuilds)
  final ValueNotifier<gmaps.CameraPosition> _mapCamera = ValueNotifier(
    const gmaps.CameraPosition(
      target: gmaps.LatLng(22.5726, 88.3639),
      zoom: 20,
    ),
  );

  // Native map layer data
  Set<gmaps.Polygon> _territoryPolygons = {};
  Set<gmaps.Marker> _territoryMarkers = {};
  List<Territory>? _lastTerritories;
  Set<String>? _lastAttackedTerritories;
  final LocationService _locationService = LocationService();
  late final SmoothLocationProvider _smoothLocation;
  LatLng _currentPosition = const LatLng(
    22.5726,
    88.3639,
  ); // Kolkata default (will be replaced by GPS)
  bool _isLoadingLocation = true;
  bool _isCalibrating = false;
  int _calibrationReadings = 0;
  final ValueNotifier<double> _heading = ValueNotifier(0.0); // Compass heading
  gmaps.BitmapDescriptor? _avatarMarkerIcon; // custom user-location icon
  int _selectedTab = 2; // 0=Health, 1=Events, 2=Map, 3=Leaderboard, 4=Profile
  final PageController _pageController = PageController(initialPage: 2);

  // ── Invasion tracking ───────────────────────────────────────────────
  /// Territory ID the current user is currently walking inside (enemy territory)
  String? _invasionTerritoryId;
  int _invasionCount = 0;

  /// Once the threshold is hit, we latch it ON for the session
  bool _invasionActivated = false;

  /// Username of the territory owner being invaded (shown in the overlay card)
  String _invasionTargetUsername = '';
  static const int _invasionThreshold =
      4; // GPS points before triggering attack

  // ── Bomb / health tracking during invasion ──────────────────────────
  /// Discrete hearts: starts at 2, each bomb hit removes 1.
  /// At 0 hearts the invader dies and loses all territories.
  int _invaderHearts = 2;
  static const int _maxHearts = 2;
  double get _invaderHealth =>
      _invaderHearts / _maxHearts; // for overlay compat
  int _invasionBombCount = 0; // total bombs triggered so far this session
  bool _invaderDead = false; // true once hearts reach 0 (prevents re-entry)

  /// Tracks which individual bombs have already exploded this session.
  /// Key format: "territoryId_bombIndex"
  final Set<String> _triggeredBombs = {};

  // ── Audio players ────────────────────────────────────────────────────
  final AudioPlayer _dangerPlayer = AudioPlayer();
  final AudioPlayer _bombPlayer = AudioPlayer();
  bool _dangerSoundPlaying = false;

  // ── Bomb explosion overlay ───────────────────────────────────────────
  bool _showBombExplosion = false;
  int _explosionBombCount = 0;
  int _explosionTopazPenalty = 0;
  Timer? _explosionTimer;

  // ── Scanner Dock / Defuse Gun gadget state ────────────────────────────
  bool _scanActive = false;         // scanner is active
  String? _scannedTerritoryId;      // which territory is being scanned
  Set<gmaps.Marker> _scanBombMarkers = {}; // yellow pins for revealed bombs
  bool _isScanLoading = false;      // true while backend call in flight
  Timer? _scanExpiryTimer;          // 15-sec countdown to hide scan results
  int _scanSecondsRemaining = 0;    // seconds left on scan reveal

  /// Periodic timer to convert expired attacks into conquests.
  Timer? _conquestTimer;
  // ────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // Territory overlay handles its own attack pulse animation internally.

    // ── Smooth location (Kalman + animated lerp) ──
    _smoothLocation = SmoothLocationProvider(
      onSmoothedLocation: (pos) {
        if (mounted) {
          setState(() {
            _currentPosition = pos;
          });
          // Smooth camera follow during active tracking
          final isTracking = Provider.of<ActivityProvider>(
            context,
            listen: false,
          ).isTracking;
          if (isTracking) {
            _gMapController?.animateCamera(
              gmaps.CameraUpdate.newLatLng(
                gmaps.LatLng(pos.latitude, pos.longitude),
              ),
            );
          }
        }
      },
    );
    _smoothLocation.attachTicker(this);

    _loadLastLocation();
    _initializeLocation();
    _loadTerritories();
    _buildAvatarMarker();

    // Periodically convert expired attacks into permanent conquests
    _conquestTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        Provider.of<TerritoryProvider>(
          context,
          listen: false,
        ).processExpiredAttacks();
      }
    });

    // Set up sensor callbacks
    _locationService.sensorService.onHeadingChanged = (heading) {
      if (mounted) {
        _heading.value = heading; // ValueNotifier — no setState needed
      }
    };

    _locationService.sensorService.onStepDetected = (steps) {
      // Step count tracking - can be used for analytics if needed
    };

    // Show safety disclaimer on first launch
    _showSafetyDisclaimerIfNeeded();
  }

  /// Shows a one-time safety disclaimer dialog to first-time users.
  Future<void> _showSafetyDisclaimerIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('safety_disclaimer_accepted') == true) return;
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.health_and_safety, color: Color(0xFFEF4444), size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Safety First!',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(ctx).colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Kingdom Runner is best enjoyed when you stay aware of your surroundings. Please read and agree:',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              _safetyPoint(
                '🚶',
                'Do NOT look at your phone while walking or running. '
                'Use audio cues and stop in a safe place to check the app.',
              ),
              const SizedBox(height: 10),
              _safetyPoint(
                '👀',
                'Always be aware of your surroundings — watch for traffic, '
                'obstacles, and other people.',
              ),
              const SizedBox(height: 10),
              _safetyPoint(
                '🌙',
                'Avoid playing in unsafe or unfamiliar areas, especially at night.',
              ),
              const SizedBox(height: 10),
              _safetyPoint(
                '🏥',
                'Stop immediately if you feel dizzy, unwell, or in pain. '
                'Your health matters more than any territory.',
              ),
            ],
          ),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () async {
                await prefs.setBool('safety_disclaimer_accepted', true);
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF16A34A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'I Understand & Agree',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _safetyPoint(String emoji, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 22)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 14, height: 1.4)),
        ),
      ],
    );
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

  // ── Avatar marker builder ─────────────────────────────────────────────
  Future<void> _buildAvatarMarker() async {
    final user = Provider.of<AuthProvider>(context, listen: false).currentUser;
    final avatarPath = user?.avatarPath;
    const double size = 120; // px (device-pixel size, rendered crisp)
    const double border = 6;

    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    final center = const Offset(size / 2, size / 2);
    final radius = size / 2;

    // Outer glow
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withOpacity(0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // White border circle
    canvas.drawCircle(center, radius, Paint()..color = Colors.white);

    // Clip to inner circle for avatar
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: radius - border)),
    );

    if (avatarPath != null && avatarPath.isNotEmpty) {
      try {
        final data = await rootBundle.load(avatarPath);
        final codec = await instantiateImageCodec(data.buffer.asUint8List());
        final frame = await codec.getNextFrame();
        final img = frame.image;
        final src = Rect.fromLTWH(
          0,
          0,
          img.width.toDouble(),
          img.height.toDouble(),
        );
        final dst = Rect.fromCircle(center: center, radius: radius - border);
        canvas.drawImageRect(img, src, dst, Paint());
      } catch (_) {
        // Fallback to solid colour + icon drawn below
        canvas.drawCircle(
          center,
          radius - border,
          Paint()..color = Theme.of(context).colorScheme.primary,
        );
      }
    } else {
      canvas.drawCircle(
        center,
        radius - border,
        Paint()..color = Theme.of(context).colorScheme.primary,
      );
    }
    canvas.restore();

    // If no avatar, draw a person icon in the centre
    if (avatarPath == null || avatarPath.isEmpty) {
      final iconPainter = TextPainter(
        text: const TextSpan(
          text: '\u{E7FD}', // Icons.person_rounded codepoint
          style: TextStyle(
            fontSize: 48,
            fontFamily: 'MaterialIcons',
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      iconPainter.paint(
        canvas,
        Offset(
          center.dx - iconPainter.width / 2,
          center.dy - iconPainter.height / 2,
        ),
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ImageByteFormat.png);
    if (bytes != null && mounted) {
      setState(() {
        _avatarMarkerIcon = gmaps.BitmapDescriptor.bytes(
          bytes.buffer.asUint8List(),
          width: size / 2, // logical size
          height: size / 2,
        );
      });
    }
  }

  // ── Topaz reward helper ────────────────────────────────────────────────
  Future<void> _showTopazModal(ActivityProvider activityProvider) async {
    if (!mounted) return;
    await TopazRewardModal.show(
      context,
      topazEarned: activityProvider.lastTopazEarned,
      totalTopaz: activityProvider.lastTotalTopaz,
      onClaim: () {}, // coins already credited on backend
    );
  }

  Future<void> _loadLastLocation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final double? lat = prefs.getDouble('last_lat');
      final double? lng = prefs.getDouble('last_lng');
      if (lat != null && lng != null) {
        setState(() {
          _currentPosition = LatLng(lat, lng);
          _isLoadingLocation = false;
        });
        _gMapController?.animateCamera(
          gmaps.CameraUpdate.newLatLngZoom(gmaps.LatLng(lat, lng), 20),
        );
      }
    } catch (e) {
      print('Error loading last location: $e');
    }
  }

  Future<void> _saveLocation(LatLng location) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('last_lat', location.latitude);
      await prefs.setDouble('last_lng', location.longitude);
    } catch (e) {
      print('Error saving location: $e');
    }
  }

  Future<void> _initializeLocation() async {
    print('📍 Initializing location services...');
    final hasPermission = await _locationService.checkPermissions();

    if (!hasPermission) {
      print('❌ Location permission denied');
      setState(() {
        _isLoadingLocation = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Location permission required for map tracking',
            ),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: () async {
                await _locationService.checkPermissions();
              },
            ),
          ),
        );
      }
      return;
    }

    print('✅ Location permission granted, getting current position...');
    final location = await _locationService.getCurrentLocation();

    if (location != null && mounted) {
      print(
        '📍 GPS location obtained: ${location.latitude}, ${location.longitude}',
      );
      _smoothLocation.jumpTo(location); // instant — no animation for first fix
      setState(() {
        _currentPosition = location;
        _isLoadingLocation = false;
      });
      _gMapController?.animateCamera(
        gmaps.CameraUpdate.newLatLngZoom(
          gmaps.LatLng(location.latitude, location.longitude),
          20,
        ),
      );
      await _saveLocation(location);
    } else {
      print('⚠️ Could not get GPS location, using default');
      setState(() {
        _isLoadingLocation = false;
      });
    }

    // Listen to location updates — feed raw GPS into the Kalman smoother.
    // The smoothed output drives setState / camera in the SmoothLocationProvider
    // callback set up in initState.
    _locationService.startTracking(
      (newLocation) async {
        if (mounted) {
          // Calibration logic - collect first 3 readings when calibrating
          if (_isCalibrating && _calibrationReadings < 3) {
            _calibrationReadings++;

            if (_calibrationReadings >= 3) {
              // Calibration complete — NOW start the actual session
              setState(() {
                _isCalibrating = false;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('✓ Location calibrated — tracking started'),
                  duration: Duration(seconds: 2),
                  backgroundColor: Colors.green,
                ),
              );
              // Start the actual tracking session after calibration
              final authProvider = Provider.of<AuthProvider>(context, listen: false);
              final activityProvider = Provider.of<ActivityProvider>(context, listen: false);
              final success = await activityProvider.startSession(
                authProvider.currentUser?.id ?? '',
              );
              if (!success && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Failed to start tracking session'),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                );
              }
            } else {
              setState(() {});
            }
            // During calibration, don't process invasion or save path
            return;
          }

          // Invasion & save use the raw (validated) position for accuracy
          _saveLocation(newLocation);
          _checkInvasion(newLocation);
        }
      },
      onLocationUpdateWithAccuracy: (location, accuracy) {
        if (mounted) {
          _smoothLocation.updateRawPosition(location, accuracyMeters: accuracy);
        }
      },
    );
  }

  Future<void> _recenterMap() async {
    // Try to get fresh GPS location
    final location = await _locationService.getCurrentLocation();
    if (location != null && mounted) {
      _smoothLocation.jumpTo(location); // reset Kalman filter for hard recenter
      setState(() {
        _currentPosition = location;
      });
      await _saveLocation(location);
      _gMapController?.animateCamera(
        gmaps.CameraUpdate.newLatLngZoom(
          gmaps.LatLng(location.latitude, location.longitude),
          20,
        ),
      );

      // Show feedback
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '📍 Location updated: ${location.latitude.toStringAsFixed(4)}, ${location.longitude.toStringAsFixed(4)}',
          ),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      // Just recenter to current position
      _gMapController?.animateCamera(
        gmaps.CameraUpdate.newLatLng(
          gmaps.LatLng(_currentPosition.latitude, _currentPosition.longitude),
        ),
      );
    }
  }

  Future<void> _loadTerritories() async {
    final territoryProvider = Provider.of<TerritoryProvider>(
      context,
      listen: false,
    );
    await territoryProvider.loadTerritories();
  }

  // ── Sound helpers ────────────────────────────────────────────────────────

  void _startDangerSound() {
    if (_dangerSoundPlaying) return;
    _dangerSoundPlaying = true;
    _dangerPlayer.setReleaseMode(ReleaseMode.loop);
    _dangerPlayer.play(AssetSource('sounds/danger.mpeg'));
  }

  void _stopDangerSound() {
    if (!_dangerSoundPlaying) return;
    _dangerSoundPlaying = false;
    _dangerPlayer.stop();
  }

  void _playBombSound() {
    _bombPlayer.play(AssetSource('sounds/bomb.mp3.mpeg'));
  }

  /// Blast radius = 20% of territory effective diameter (matches bomb_placement_screen).
  double _bombBlastRadius(double territoryArea) {
    if (territoryArea <= 0) return 10;
    final diameter = 2 * math.sqrt(territoryArea / math.pi);
    return (diameter * 0.20).clamp(5.0, 200.0);
  }

  /// Haversine distance in metres between two LatLng points.
  double _distanceMeters(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180.0;
    final dLng = (b.longitude - a.longitude) * math.pi / 180.0;
    final sinLat = math.sin(dLat / 2);
    final sinLng = math.sin(dLng / 2);
    final h =
        sinLat * sinLat +
        math.cos(a.latitude * math.pi / 180.0) *
            math.cos(b.latitude * math.pi / 180.0) *
            sinLng *
            sinLng;
    return R * 2 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
  }

  // ── Invasion & bomb proximity detection ──────────────────────────────
  void _checkInvasion(LatLng position) {
    // If already dead this session, skip further checks
    if (_invaderDead) return;

    final activityProvider = Provider.of<ActivityProvider>(
      context,
      listen: false,
    );
    if (!activityProvider.isTracking) {
      _stopDangerSound();
      _invasionTerritoryId = null;
      _invasionCount = 0;
      _invasionActivated = false;
      return;
    }

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final territoryProvider = Provider.of<TerritoryProvider>(
      context,
      listen: false,
    );
    final currentUserId = authProvider.currentUser?.id ?? '';

    // ── 1. Detect if user is inside an enemy territory polygon ──────────
    bool insideEnemy = false;

    for (final territory in territoryProvider.territories) {
      if (territory.userId == currentUserId) continue;
      if (territory.polygon.length < 3) continue;

      if (_locationService.isPointInPolygon(position, territory.polygon)) {
        insideEnemy = true;

        if (_invasionTerritoryId == territory.id) {
          _invasionCount++;
        } else {
          // Entered a different (or new) enemy territory — reset scan too
          final isFirstEntry = _invasionTerritoryId == null;
          _invasionTerritoryId = territory.id;
          _invasionCount = 1;
          _invasionActivated = false;
          _invasionBombCount = territory.bombCount;
          _scanExpiryTimer?.cancel();
          _scanActive = false;
          _scannedTerritoryId = null;
          _scanBombMarkers = {};
          _scanSecondsRemaining = 0;
          if (isFirstEntry) _startDangerSound();
        }

        // Report attack after threshold (does not gate bombs)
        if (_invasionCount == _invasionThreshold && !_invasionActivated) {
          _invasionActivated = true;
          final attackerUsername =
              authProvider.currentUser?.username ?? 'Attacker';
          territoryProvider.reportAttack(
            territory.id,
            attackerUsername,
            attackerTerritoryId:
                territoryProvider.getTerritoriesByUser(currentUserId).isNotEmpty
                ? territoryProvider.getTerritoriesByUser(currentUserId).first.id
                : null,
          );
          if (mounted) {
            setState(() {
              _invasionTargetUsername = territory.username;
            });
          }
          // Also report to backend so DEFENDER can see the invasion
          territoryProvider.reportInvasionToBackend(territory.id);
        }
        break; // only track one enemy territory at a time
      }
    }

    // ── 2. Per-bomb proximity check (runs on EVERY GPS tick) ────────────
    // Check ALL enemy territories' bombs regardless of polygon containment,
    // so a bomb near the edge still triggers.
    for (final territory in territoryProvider.territories) {
      if (territory.userId == currentUserId) continue;
      if (territory.bombCount == 0 || territory.bombPositions.isEmpty) continue;

      final blastR = _bombBlastRadius(territory.area);

      for (int i = 0; i < territory.bombPositions.length; i++) {
        final bombKey = '${territory.id}_$i';
        if (_triggeredBombs.contains(bombKey)) continue; // already exploded

        final bombPos = territory.bombPositions[i];
        final dist = _distanceMeters(position, bombPos);

        if (dist <= blastR) {
          // ── BOMB TRIGGERED! ──────────────────────────────────────────
          _triggeredBombs.add(bombKey);

          // If not already inside an enemy territory, activate invasion UI
          if (_invasionTerritoryId == null) {
            _invasionTerritoryId = territory.id;
            _invasionCount = 1;
            _invasionBombCount = territory.bombCount;
            _startDangerSound();
            insideEnemy = true;
          }

          // Remove 1 heart
          setState(() {
            _invaderHearts = (_invaderHearts - 1).clamp(0, _maxHearts);
            _invasionBombCount = _triggeredBombs
                .where((k) => k.startsWith(territory.id))
                .length;
            // Show explosion overlay
            _showBombExplosion = true;
            _explosionBombCount = 1;
            _explosionTopazPenalty = 30; // BOMB_TOPAZ_PENALTY from backend
          });

          _playBombSound();

          // Auto-dismiss explosion after 3 seconds
          _explosionTimer?.cancel();
          _explosionTimer = Timer(const Duration(milliseconds: 3000), () {
            if (mounted) setState(() => _showBombExplosion = false);
          });

          // Call backend to apply bomb penalty and consume the bomb permanently
          final detonatedTerritoryId = territory.id;
          final detonatedLat = bombPos.latitude;
          final detonatedLng = bombPos.longitude;
          final detonatedIndex = i;
          authProvider.apiService
              .applyBombDamage(
                detonatedTerritoryId,
                lat: detonatedLat,
                lng: detonatedLng,
              )
              .then((result) {
                // Reload user topaz
                authProvider.loadCurrentUser();
                // Remove the consumed bomb from the local territory model
                final newBombCount =
                    (result['bombCount'] as num?)?.toInt() ?? 0;
                final rawPos = result['bombPositions'] as List<dynamic>?;
                final newPositions = rawPos
                    ?.map(
                      (p) => LatLng(
                        (p['lat'] as num).toDouble(),
                        (p['lng'] as num).toDouble(),
                      ),
                    )
                    .toList();
                territoryProvider.updateTerritoryBombCount(
                  detonatedTerritoryId,
                  newBombCount,
                  newPositions: newPositions,
                );
                // Remove the detonated bomb's scan marker if scanner was active
                if (_scanActive && mounted) {
                  setState(() {
                    _scanBombMarkers.removeWhere(
                      (m) =>
                          m.markerId.value ==
                          'scan_bomb_${detonatedTerritoryId}_$detonatedIndex',
                    );
                  });
                }
              })
              .catchError((_) {});

          // ── DEATH CHECK ────────────────────────────────────────────
          if (_invaderHearts <= 0) {
            _handleInvaderDeath(
              currentUserId,
              territoryProvider,
              authProvider,
              activityProvider,
            );
            return; // stop processing more bombs
          }

          // Only trigger one bomb per GPS tick to space out explosions
          return;
        }
      }
    }

    // ── 3. Left all enemy territory → reset ─────────────────────────────
    if (!insideEnemy && _invasionTerritoryId != null) {
      _stopDangerSound();
      if (mounted) {
        setState(() {
          _invasionTerritoryId = null;
          _invasionCount = 0;
          _invasionActivated = false;
          _invasionTargetUsername = '';
          _invaderHearts = _maxHearts; // restore hearts when safe
          _invasionBombCount = 0;
          _triggeredBombs.clear();
          // Clear gadget state when leaving enemy territory
          _scanExpiryTimer?.cancel();
          _scanActive = false;
          _scannedTerritoryId = null;
          _scanBombMarkers = {};
          _scanSecondsRemaining = 0;
        });
      }
    }
  }

  /// Called when invader's hearts reach 0.
  /// Stops the active session, deletes all of the invader's territories,
  /// shows a death dialog, then navigates back to the map tab.
  Future<void> _handleInvaderDeath(
    String userId,
    TerritoryProvider territoryProvider,
    AuthProvider authProvider,
    ActivityProvider activityProvider,
  ) async {
    _invaderDead = true;
    _stopDangerSound();

    // Stop the active GPS tracking session so the run is ended
    await activityProvider.stopSession();

    // Delete all territories on server + locally
    await territoryProvider.removeAllUserTerritories(userId);
    authProvider.loadCurrentUser(); // refresh topaz / stats

    if (!mounted) return;

    // Show death dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Text('💀', style: TextStyle(fontSize: 28)),
            SizedBox(width: 10),
            Text(
              'YOU DIED!',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w900,
                fontSize: 22,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'You stepped on bombs and lost all your hearts!',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            SizedBox(height: 12),
            Text(
              'All your territories have been destroyed.',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Walk and create new territories to rebuild your kingdom.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Reset invasion state and go back to map tab
              if (mounted) {
                setState(() {
                  _invaderDead = false;
                  _invaderHearts = _maxHearts;
                  _invasionTerritoryId = null;
                  _invasionCount = 0;
                  _invasionActivated = false;
                  _invasionTargetUsername = '';
                  _invasionBombCount = 0;
                  _triggeredBombs.clear();
                  // Clear gadget state
                  _scanExpiryTimer?.cancel();
                  _scanActive = false;
                  _scannedTerritoryId = null;
                  _scanBombMarkers = {};
                  _scanSecondsRemaining = 0;
                });
                _pageController.animateToPage(
                  2,
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeInOut,
                );
              }
            },
            child: const Text(
              'OK',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }
  // ────────────────────────────────────────────────────────────────

  // ── Scanner Dock & Defuse Gun methods ──────────────────────────────────

  /// Shows a bottom-sheet picker of enemy territories that have bombs.
  Future<String?> _showTerritoryPicker(List<Territory> territories) async {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SvgPicture.asset('assets/dog.svg', width: 22, height: 22),
                const SizedBox(width: 10),
                const Text(
                  'Select Territory to Scan',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Pick an enemy territory to reveal hidden bombs for 15 seconds.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 16),
            ...territories.map((t) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                leading: const Icon(Icons.radar, color: Color(0xFF0891B2)),
                title: Text(
                  '${t.username}\'s Territory',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                ),
                subtitle: Text(
                  '${t.bombCount} bomb${t.bombCount == 1 ? '' : 's'} • ${t.area.toStringAsFixed(0)} m²',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white38, size: 14),
                onTap: () => Navigator.pop(ctx, t.id),
              ),
            )),
          ],
        ),
      ),
    );
  }

  /// Activates scanning for an enemy territory.
  /// If inside enemy territory, scans that one directly.
  /// Otherwise shows a territory picker dialog.
  /// Costs 1 Scanner Dock; reveals bomb positions for 15 seconds.
  Future<void> _activateScan() async {
    if (_scanActive || _isScanLoading) return;

    final auth = Provider.of<AuthProvider>(context, listen: false);
    final tp = Provider.of<TerritoryProvider>(context, listen: false);
    final currentUserId = auth.currentUser?.id ?? '';

    // Determine target territory
    String? targetId;
    if (_invasionTerritoryId != null) {
      targetId = _invasionTerritoryId;
    } else {
      // Not inside enemy territory — show picker of enemy territories with bombs
      final enemyTerritories = tp.territories
          .where((t) => t.userId != currentUserId && t.bombCount > 0)
          .toList();
      if (enemyTerritories.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No enemy territories with bombs detected nearby.'),
            ),
          );
        }
        return;
      }
      targetId = await _showTerritoryPicker(enemyTerritories);
      if (targetId == null || !mounted) return; // user cancelled
    }

    setState(() => _isScanLoading = true);

    try {
      await auth.apiService.useScannerDock();
      await auth.loadCurrentUser();
    } catch (e) {
      if (mounted) {
        setState(() => _isScanLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
        );
      }
      return;
    }

    if (!mounted) return;

    // Find the target territory's bomb positions
    Territory? target;
    for (final t in tp.territories) {
      if (t.id == targetId) {
        target = t;
        break;
      }
    }

    final bombs = target?.bombPositions ?? [];
    final tId = targetId!;
    final newMarkers = <gmaps.Marker>{};

    for (int i = 0; i < bombs.length; i++) {
      final bomb = bombs[i];
      final bombIdx = i;
      newMarkers.add(
        gmaps.Marker(
          markerId: gmaps.MarkerId('scan_bomb_${tId}_$i'),
          position: gmaps.LatLng(bomb.latitude, bomb.longitude),
          icon: gmaps.BitmapDescriptor.defaultMarkerWithHue(
            gmaps.BitmapDescriptor.hueYellow,
          ),
          infoWindow: const gmaps.InfoWindow(
            title: '💣 Enemy Bomb Detected',
            snippet: 'Tap to defuse with a Defuse Gun',
          ),
          onTap: () => _onScanBombTap(tId, bombIdx, bomb),
        ),
      );
    }

    setState(() {
      _scanActive = true;
      _scannedTerritoryId = tId;
      _scanBombMarkers = newMarkers;
      _isScanLoading = false;
      _scanSecondsRemaining = 15;
    });

    // Start 15-second countdown — bomb locations vanish when timer runs out
    _scanExpiryTimer?.cancel();
    _scanExpiryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      setState(() {
        _scanSecondsRemaining--;
        if (_scanSecondsRemaining <= 0) {
          timer.cancel();
          _scanActive = false;
          _scannedTerritoryId = null;
          _scanBombMarkers = {};
        }
      });
    });
  }

  /// Called when the user taps a revealed scan bomb marker.
  void _onScanBombTap(String territoryId, int bombIndex, LatLng position) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final defuseCount = auth.currentUser?.defuseGunInventory ?? 0;

    if (defuseCount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No Defuse Guns in inventory — buy one from the Armory!'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Defuse Bomb?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Use 1 Defuse Gun to permanently destroy this bomb?\n\nYou have $defuseCount Defuse Gun(s).',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _doDefuse(territoryId, bombIndex, position);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF059669),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Defuse'),
          ),
        ],
      ),
    );
  }

  /// Calls the backend to defuse one bomb, removes the marker, refreshes territory data.
  Future<void> _doDefuse(
    String territoryId,
    int bombIndex,
    LatLng position,
  ) async {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final tp = Provider.of<TerritoryProvider>(context, listen: false);

    try {
      await auth.apiService.defuseBomb(
        territoryId,
        position.latitude,
        position.longitude,
      );
      await Future.wait([auth.loadCurrentUser(), tp.loadTerritories()]);

      if (mounted) {
        setState(() {
          _scanBombMarkers.removeWhere(
            (m) => m.markerId.value == 'scan_bomb_${territoryId}_$bombIndex',
          );
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Bomb defused! The threat is neutralised.'),
            backgroundColor: Color(0xFF059669),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final activityProvider = Provider.of<ActivityProvider>(context);
    final territoryProvider = Provider.of<TerritoryProvider>(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDarkMode = themeProvider.isDarkMode;

    // Build Google Maps polyline for current path
    final Set<gmaps.Polyline> gmapsPolylines = {};
    if (activityProvider.isTracking &&
        !_isCalibrating &&
        activityProvider.currentPath.isNotEmpty) {
      gmapsPolylines.add(
        gmaps.Polyline(
          polylineId: const gmaps.PolylineId('current_path'),
          points: activityProvider.currentPath
              .map((p) => gmaps.LatLng(p.latitude, p.longitude))
              .toList(),
          color: isDarkMode
              ? Colors.white.withOpacity(0.8)
              : const Color(0xFF2E7D32).withOpacity(0.85),
          width: 4,
        ),
      );
    }

    // Territory data for the overlay and tap handler
    final currentUserId = authProvider.currentUser?.id ?? '';

    // Update the native polygons and markers if the territories have changed
    if (_lastTerritories != territoryProvider.territories) {
      _lastTerritories = territoryProvider.territories;
      KingdomNativeMapGenerator.generate(
        territoryProvider.territories,
        currentUserId,
        attackedTerritoryIds: territoryProvider.attackedTerritoryIds,
        onCastleTap: (territoryId) {
          final territories = territoryProvider.territories;
          final colored = TerritoryColorAssigner.assign(territories);
          final idx = territories.indexWhere((t) => t.id == territoryId);
          if (idx == -1) return;
          final territory = territories[idx];
          final ct = colored.firstWhere((c) => c.territory.id == territoryId);
          showTerritoryStats(
            context,
            territory,
            ct,
            currentUserId: currentUserId,
          );
        },
      ).then((res) {
        if (mounted) {
          setState(() {
            _territoryPolygons = res.polygons;
            _territoryMarkers = res.markers;
          });
        }
      });
    }

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Stack(
          children: [
            PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) => setState(() => _selectedTab = i),
              children: [
                _KeepAlive(child: const HealthScreen()),
                _KeepAlive(child: const EventsScreen()),
                // Map page — wrapped in _KeepAlive so the heavy GoogleMap
                // platform view survives tab switches.
                _KeepAlive(
                  child: SizedBox.expand(
                    child: Stack(
                      children: [
                        // Map layer – Google Maps
                        Positioned.fill(
                          child: gmaps.GoogleMap(
                            mapType: gmaps.MapType.normal,
                            initialCameraPosition: gmaps.CameraPosition(
                              target: gmaps.LatLng(
                                _currentPosition.latitude,
                                _currentPosition.longitude,
                              ),
                              zoom: 20,
                            ),
                            onMapCreated: (controller) async {
                              print('🗺️ GoogleMap onMapCreated fired');
                              _gMapController = controller;
                              if (!_mapCompleter.isCompleted) {
                                _mapCompleter.complete(controller);
                              }
                              _lastDarkMode = isDarkMode;
                              if (isDarkMode) {
                                try {
                                  await controller.setMapStyle(
                                    GoogleMapsConfig.darkMapStyle,
                                  );
                                  print('🗺️ Dark map style applied');
                                } catch (e) {
                                  print('🗺️ setMapStyle error: $e');
                                }
                              }
                            },
                            onCameraMove: (pos) => _mapCamera.value = pos,
                            onTap: (pos) =>
                                KingdomTerritoryOverlay.handleMapTap(
                                  context,
                                  pos,
                                  territoryProvider.territories,
                                  currentUserId,
                                ),
                            myLocationEnabled: _avatarMarkerIcon == null,
                            myLocationButtonEnabled: false,
                            polygons: _territoryPolygons,
                            markers: {
                              ..._territoryMarkers,
                              ..._scanBombMarkers,
                              if (_avatarMarkerIcon != null)
                                gmaps.Marker(
                                  markerId: const gmaps.MarkerId(
                                    'user_location',
                                  ),
                                  position: gmaps.LatLng(
                                    _currentPosition.latitude,
                                    _currentPosition.longitude,
                                  ),
                                  icon: _avatarMarkerIcon!,
                                  anchor: const Offset(0.5, 0.5),
                                  flat: true,
                                  zIndex: 999,
                                ),
                            },
                            compassEnabled: false,
                            zoomControlsEnabled: false,
                            rotateGesturesEnabled: true,
                            tiltGesturesEnabled: false,
                            polylines: gmapsPolylines,
                          ),
                        ),
                        // ── Danger vignette: shown as soon as user steps into enemy ground ──
                        if (_invasionTerritoryId != null)
                          Positioned.fill(
                            child: _DangerInvasionOverlay(
                              health: _invaderHealth,
                              hearts: _invaderHearts,
                              maxHearts: _maxHearts,
                              bombCount: _invasionBombCount,
                            ),
                          ),
                        // ── Bomb explosion overlay ────────────────────────────
                        if (_showBombExplosion)
                          Positioned.fill(
                            child: _BombExplosionOverlay(
                              bombCount: _explosionBombCount,
                              topazPenalty: _explosionTopazPenalty,
                            ),
                          ),
                        // ── Persistent hearts HUD during tracking ─────────────
                        if (activityProvider.isTracking)
                          Positioned(
                            top: 50,
                            right: 70,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.55),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: _invaderHearts < _maxHearts
                                      ? Colors.redAccent.withOpacity(0.6)
                                      : Colors.white24,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: List.generate(_maxHearts, (i) {
                                  final filled = i < _invaderHearts;
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                    ),
                                    child: Icon(
                                      filled
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                      color: filled
                                          ? const Color(0xFFEF4444)
                                          : Colors.white30,
                                      size: 20,
                                    ),
                                  );
                                }),
                              ),
                            ),
                          ),
                        // Compass widget — uses ValueListenableBuilder to avoid
                        // rebuilding the entire widget tree on every heading change.
                        Positioned(
                          top: 50,
                          left: 16,
                          child: ValueListenableBuilder<double>(
                            valueListenable: _heading,
                            builder: (_, heading, __) => CompassWidget(
                              heading: heading,
                              size: 70,
                              showDegrees: true,
                            ),
                          ),
                        ),
                        // ── Gadgets HUD — shown whenever tracking with gadgets ──
                        if (activityProvider.isTracking &&
                            ((authProvider.currentUser?.scannerDockInventory ?? 0) > 0 ||
                             (authProvider.currentUser?.defuseGunInventory ?? 0) > 0 ||
                             _scanActive))
                          Positioned(
                            top: 130,
                            left: 16,
                            child: _GadgetsHUD(
                              scanActive: _scanActive,
                              isScanLoading: _isScanLoading,
                              scannerDockCount: authProvider.currentUser?.scannerDockInventory ?? 0,
                              defuseGunCount: authProvider.currentUser?.defuseGunInventory ?? 0,
                              scannedBombCount: _scanBombMarkers.length,
                              scanSecondsRemaining: _scanSecondsRemaining,
                              onScan: (!_scanActive &&
                                      !_isScanLoading &&
                                      (authProvider.currentUser?.scannerDockInventory ?? 0) > 0)
                                  ? _activateScan
                                  : null,
                            ),
                          ),
                        // ── Persistent invasion alert card ────────────────────
                        if (_invasionActivated &&
                            _invasionTargetUsername.isNotEmpty)
                          Positioned(
                            bottom: 170,
                            left: 16,
                            right: 16,
                            child: _InvasionAlertCard(
                              targetUsername: _invasionTargetUsername,
                              onDismiss: () {
                                setState(() {
                                  _invasionActivated = false;
                                  _invasionTargetUsername = '';
                                });
                              },
                            ),
                          ),
                        // Recenter button
                        Positioned(
                          top: 50,
                          right: 16,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.1),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(
                                  sigmaX: 10,
                                  sigmaY: 10,
                                ),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: isDarkMode
                                        ? const Color(0xFFE4E4E7).withOpacity(
                                            0.95,
                                          ) // Bright zinc-200 for map
                                        : Colors.white.withOpacity(0.9),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: isDarkMode
                                          ? const Color(0xFFF4F4F5).withOpacity(
                                              0.6,
                                            ) // zinc-100
                                          : Colors.white.withOpacity(0.2),
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(16),
                                      onTap: _recenterMap,
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Icon(
                                          Icons.my_location,
                                          color: isDarkMode
                                              ? Colors.black87
                                              : Colors.black87,
                                          size: 24,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Floating Start button — visible when not tracking (or during calibration to cancel)
                        if (!activityProvider.isTracking || _isCalibrating)
                          Positioned(
                            bottom: 120,
                            right: 16,
                            child: GestureDetector(
                              onTap: () async {
                                if (activityProvider.isTracking ||
                                    _isCalibrating) {
                                  // Reset invasion state on stop (also hides overlay card)
                                  setState(() {
                                    _invasionTerritoryId = null;
                                    _invasionCount = 0;
                                    _invasionActivated = false;
                                    _invasionTargetUsername = '';
                                  });

                                  // Stop calibration if it was in progress
                                  if (_isCalibrating) {
                                    setState(() {
                                      _isCalibrating = false;
                                      _calibrationReadings = 0;
                                    });
                                    // Session hasn't started yet during calibration, just return
                                    return;
                                  }

                                  final session = await activityProvider
                                      .stopSession();

                                  if (session != null && mounted) {
                                    // ALWAYS reload territories and user stats after session ends
                                    await _loadTerritories();
                                    await authProvider.loadCurrentUser();

                                    // Check if territory was created
                                    if (session.territoryId != null) {
                                      await _showTopazModal(activityProvider);
                                    } else if (activityProvider
                                            .currentPath
                                            .length <
                                        3) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Row(
                                            children: [
                                              Icon(
                                                Icons.info_outline,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurface,
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  'Walk more to create a territory (need at least 3 points)',
                                                  style: TextStyle(
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.onSurface,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          backgroundColor: Theme.of(
                                            context,
                                          ).colorScheme.surface,
                                          behavior: SnackBarBehavior.floating,
                                          duration: const Duration(seconds: 4),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                        ),
                                      );
                                    } else {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Row(
                                            children: [
                                              Icon(
                                                Icons.check_circle_outline,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurface,
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  'Session saved. Territory area may be too small.',
                                                  style: TextStyle(
                                                    color: Theme.of(
                                                      context,
                                                    ).colorScheme.onSurface,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          backgroundColor: Theme.of(
                                            context,
                                          ).colorScheme.surface,
                                          behavior: SnackBarBehavior.floating,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                } else {
                                  // Start calibration — session will start after calibration completes
                                  setState(() {
                                    _isCalibrating = true;
                                    _calibrationReadings = 0;
                                  });
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: _isCalibrating
                                        ? [
                                            const Color(0xFFD97706),
                                            const Color(0xFFB45309),
                                          ]
                                        : activityProvider.isTracking
                                        ? [
                                            const Color(0xFFDC2626),
                                            const Color(0xFFB91C1C),
                                          ]
                                        : [
                                            Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ],
                                  ),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          (_isCalibrating
                                                  ? const Color(0xFFD97706)
                                                  : activityProvider.isTracking
                                                  ? const Color(0xFFDC2626)
                                                  : Theme.of(
                                                      context,
                                                    ).colorScheme.primary)
                                              .withOpacity(0.4),
                                      blurRadius: 15,
                                      spreadRadius: 2,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  _isCalibrating
                                      ? Icons.sensors_rounded
                                      : activityProvider.isTracking
                                      ? Icons.stop_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 32,
                                ),
                              ),
                            ),
                          ),
                        if (activityProvider.isTracking && !_isCalibrating)
                          Positioned(
                            bottom: 100,
                            left: 16,
                            right: 16,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(
                                  sigmaX: 10,
                                  sigmaY: 10,
                                ),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: isDarkMode
                                        ? const Color(
                                            0xFFE4E4E7,
                                          ).withOpacity(0.95)
                                        : Colors.white.withOpacity(0.9),
                                    borderRadius: BorderRadius.circular(24),
                                    border: Border.all(
                                      color: isDarkMode
                                          ? const Color(
                                              0xFFF4F4F5,
                                            ).withOpacity(0.5)
                                          : Colors.white.withOpacity(0.5),
                                      width: 1.5,
                                    ),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 18,
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: [
                                      // ── Distance ──
                                      Expanded(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.straighten,
                                              size: 24,
                                              color: Colors.black87,
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              formatDistance(
                                                activityProvider
                                                    .currentDistance,
                                              ).split(' ')[0],
                                              style: const TextStyle(
                                                fontSize: 22,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.black87,
                                              ),
                                            ),
                                            Text(
                                              formatDistance(
                                                activityProvider
                                                    .currentDistance,
                                              ).split(' ')[1],
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: Colors.black54,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        width: 1,
                                        height: 56,
                                        color: Colors.black.withOpacity(0.1),
                                      ),
                                      // ── STOP button (centre) ──
                                      GestureDetector(
                                        onTap: () async {
                                          setState(() {
                                            _invasionTerritoryId = null;
                                            _invasionCount = 0;
                                            _invasionActivated = false;
                                            _invasionTargetUsername = '';
                                          });
                                          final session = await activityProvider
                                              .stopSession();
                                          if (session != null && mounted) {
                                            await _loadTerritories();
                                            await authProvider
                                                .loadCurrentUser();
                                            if (session.territoryId != null) {
                                              await _showTopazModal(
                                                activityProvider,
                                              );
                                            } else {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Row(
                                                    children: [
                                                      Icon(
                                                        Icons
                                                            .check_circle_outline,
                                                        color: Theme.of(
                                                          context,
                                                        ).colorScheme.onSurface,
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child: Text(
                                                          'Session saved.',
                                                          style: TextStyle(
                                                            color:
                                                                Theme.of(
                                                                      context,
                                                                    )
                                                                    .colorScheme
                                                                    .onSurface,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  backgroundColor: Theme.of(
                                                    context,
                                                  ).colorScheme.surface,
                                                  behavior:
                                                      SnackBarBehavior.floating,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                  ),
                                                ),
                                              );
                                            }
                                          }
                                        },
                                        child: Container(
                                          width: 64,
                                          height: 64,
                                          decoration: BoxDecoration(
                                            gradient: const LinearGradient(
                                              begin: Alignment.topLeft,
                                              end: Alignment.bottomRight,
                                              colors: [
                                                Color(0xFFDC2626),
                                                Color(0xFFB91C1C),
                                              ],
                                            ),
                                            shape: BoxShape.circle,
                                            boxShadow: [
                                              BoxShadow(
                                                color: const Color(
                                                  0xFFDC2626,
                                                ).withOpacity(0.45),
                                                blurRadius: 16,
                                                spreadRadius: 2,
                                                offset: const Offset(0, 4),
                                              ),
                                            ],
                                          ),
                                          child: const Icon(
                                            Icons.stop_rounded,
                                            color: Colors.white,
                                            size: 32,
                                          ),
                                        ),
                                      ),
                                      Container(
                                        width: 1,
                                        height: 56,
                                        color: Colors.black.withOpacity(0.1),
                                      ),
                                      // ── Points ──
                                      Expanded(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.timeline,
                                              size: 24,
                                              color: Colors.black87,
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              '${activityProvider.currentPath.length}',
                                              style: const TextStyle(
                                                fontSize: 22,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.black87,
                                              ),
                                            ),
                                            const Text(
                                              'points',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Colors.black54,
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
                        if (_isCalibrating)
                          Positioned.fill(
                            child: Container(
                              color: Colors.black.withOpacity(0.65),
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(32),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(24),
                                    child: BackdropFilter(
                                      filter: ImageFilter.blur(
                                        sigmaX: 12,
                                        sigmaY: 12,
                                      ),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 28,
                                          vertical: 32,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surface
                                              .withOpacity(0.92),
                                          borderRadius: BorderRadius.circular(
                                            24,
                                          ),
                                          border: Border.all(
                                            color: Theme.of(
                                              context,
                                            ).dividerColor,
                                            width: 1.5,
                                          ),
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            // Icon with amber glow
                                            Container(
                                              width: 72,
                                              height: 72,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: const Color(
                                                  0xFFD97706,
                                                ).withOpacity(0.15),
                                                border: Border.all(
                                                  color: const Color(
                                                    0xFFD97706,
                                                  ).withOpacity(0.5),
                                                  width: 2,
                                                ),
                                              ),
                                              child: const Icon(
                                                Icons.sensors_rounded,
                                                size: 36,
                                                color: Color(0xFFD97706),
                                              ),
                                            ),
                                            const SizedBox(height: 20),
                                            Text(
                                              'Calibrating Location',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleLarge
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                            ),
                                            const SizedBox(height: 8),
                                            Text(
                                              'Stand still for a moment so we can\nlock onto your position accurately',
                                              textAlign: TextAlign.center,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                            ),
                                            const SizedBox(height: 24),
                                            // Progress bar
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              child: LinearProgressIndicator(
                                                value: _calibrationReadings / 3,
                                                minHeight: 8,
                                                backgroundColor: Theme.of(
                                                  context,
                                                ).dividerColor,
                                                valueColor:
                                                    const AlwaysStoppedAnimation<
                                                      Color
                                                    >(Color(0xFFD97706)),
                                              ),
                                            ),
                                            const SizedBox(height: 10),
                                            Text(
                                              '${_calibrationReadings} / 3 readings',
                                              style: Theme.of(
                                                context,
                                              ).textTheme.labelSmall,
                                            ),
                                            const SizedBox(height: 24),
                                            // Stop calibration button
                                            SizedBox(
                                              width: double.infinity,
                                              child: OutlinedButton.icon(
                                                onPressed: () {
                                                  setState(() {
                                                    _isCalibrating = false;
                                                    _calibrationReadings = 0;
                                                  });
                                                  // No session to stop — session only starts after calibration
                                                },
                                                icon: const Icon(
                                                  Icons.close_rounded,
                                                  size: 18,
                                                ),
                                                label: const Text(
                                                  'Stop Calibration',
                                                ),
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor: const Color(
                                                    0xFFDC2626,
                                                  ),
                                                  side: const BorderSide(
                                                    color: Color(0xFFDC2626),
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        vertical: 12,
                                                      ),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          12,
                                                        ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        // ── Vehicle warning overlay ─────────────────────────────
                        if (activityProvider.vehicleWarningState ==
                                VehicleWarningState.warning ||
                            activityProvider.vehicleWarningState ==
                                VehicleWarningState.terminated)
                          _VehicleWarningOverlay(
                            state: activityProvider.vehicleWarningState,
                            speedKmh: activityProvider.detectedVehicleSpeedKmh,
                            secondsRemaining:
                                activityProvider.warningSecondsRemaining,
                            onDismiss: () {
                              activityProvider.dismissVehicleWarning();
                            },
                            onStop: () async {
                              activityProvider.dismissVehicleWarning();
                              await activityProvider.stopSession();
                              if (mounted) {
                                await _loadTerritories();
                                final auth = Provider.of<AuthProvider>(
                                  context,
                                  listen: false,
                                );
                                await auth.loadCurrentUser();
                              }
                            },
                          ),
                        // ────────────────────────────────────────────────────────
                      ],
                    ),
                  ),
                ),
                _KeepAlive(child: const LeaderboardScreen()),
                _KeepAlive(child: const ProfileScreen()),
              ],
            ),
            // Floating dock — always visible on all tabs
            Positioned(
              bottom: 30,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 320),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withOpacity(0.25),
                        blurRadius: 20,
                        spreadRadius: 2,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surface.withOpacity(0.92),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildDockItem(
                              context: context,
                              icon: Icons.water_drop_rounded,
                              isSelected: _selectedTab == 0,
                              onTap: () => _pageController.animateToPage(
                                0,
                                duration: const Duration(milliseconds: 380),
                                curve: Curves.easeInOutCubic,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _buildDockItem(
                              context: context,
                              icon: Icons.groups_rounded,
                              isSelected: _selectedTab == 1,
                              onTap: () => _pageController.animateToPage(
                                1,
                                duration: const Duration(milliseconds: 380),
                                curve: Curves.easeInOutCubic,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _buildDockItem(
                              context: context,
                              icon: Icons.location_city,
                              isSelected: _selectedTab == 2,
                              onTap: () => _pageController.animateToPage(
                                2,
                                duration: const Duration(milliseconds: 380),
                                curve: Curves.easeInOutCubic,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _buildDockItem(
                              context: context,
                              icon: Icons.leaderboard_outlined,
                              isSelected: _selectedTab == 3,
                              onTap: () => _pageController.animateToPage(
                                3,
                                duration: const Duration(milliseconds: 380),
                                curve: Curves.easeInOutCubic,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _buildDockItem(
                              context: context,
                              icon: Icons.person_outline_rounded,
                              isSelected: _selectedTab == 4,
                              onTap: () => _pageController.animateToPage(
                                4,
                                duration: const Duration(milliseconds: 380),
                                curve: Curves.easeInOutCubic,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDockItem({
    required BuildContext context,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? primary : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: TweenAnimationBuilder<Color?>(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          tween: ColorTween(
            begin: onSurface.withOpacity(0.55),
            end: isSelected ? onPrimary : onSurface.withOpacity(0.55),
          ),
          builder: (context, color, child) {
            return Icon(icon, color: color, size: 24);
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _conquestTimer?.cancel();
    _explosionTimer?.cancel();
    _scanExpiryTimer?.cancel();
    _dangerPlayer.stop();
    _dangerPlayer.dispose();
    _bombPlayer.stop();
    _bombPlayer.dispose();
    _smoothLocation.dispose();
    _pageController.dispose();
    _mapCamera.dispose();
    _heading.dispose();
    _gMapController?.dispose();
    _locationService.dispose();
    super.dispose();
  }
}

// ── Vehicle Warning Overlay ────────────────────────────────────────────────
class _VehicleWarningOverlay extends StatelessWidget {
  final VehicleWarningState state;
  final double speedKmh;
  final int secondsRemaining;
  final VoidCallback onDismiss;
  final Future<void> Function() onStop;

  const _VehicleWarningOverlay({
    required this.state,
    required this.speedKmh,
    required this.secondsRemaining,
    required this.onDismiss,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final isTerminated = state == VehicleWarningState.terminated;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.72),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 32,
                  ),
                  decoration: BoxDecoration(
                    color: isTerminated
                        ? const Color(0xFF7F1D1D).withOpacity(0.92)
                        : const Color(0xFF78350F).withOpacity(0.92),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: isTerminated
                          ? const Color(0xFFEF4444).withOpacity(0.7)
                          : const Color(0xFFF59E0B).withOpacity(0.7),
                      width: 1.5,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Icon
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              (isTerminated
                                      ? const Color(0xFFEF4444)
                                      : const Color(0xFFF59E0B))
                                  .withOpacity(0.18),
                          border: Border.all(
                            color:
                                (isTerminated
                                        ? const Color(0xFFEF4444)
                                        : const Color(0xFFF59E0B))
                                    .withOpacity(0.6),
                            width: 2,
                          ),
                        ),
                        child: Icon(
                          isTerminated
                              ? Icons.block_rounded
                              : Icons.directions_bus_rounded,
                          size: 36,
                          color: isTerminated
                              ? const Color(0xFFEF4444)
                              : const Color(0xFFF59E0B),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // Title
                      Text(
                        isTerminated
                            ? 'Session Terminated'
                            : 'Vehicle Detected!',
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),

                      const SizedBox(height: 10),

                      // Body
                      Text(
                        isTerminated
                            ? 'Your session was ended because you appeared to be travelling by vehicle.'
                            : 'You appear to be in a bus, train, or car\n(${speedKmh.toStringAsFixed(0)} km/h).\n\nStop now or the session will end.',
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.white70,
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),

                      // Countdown ring (only during warning)
                      if (!isTerminated) ...[
                        const SizedBox(height: 20),
                        SizedBox(
                          width: 64,
                          height: 64,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: secondsRemaining / 15.0,
                                strokeWidth: 5,
                                backgroundColor: Colors.white.withOpacity(0.15),
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Color(0xFFF59E0B),
                                ),
                              ),
                              Text(
                                '$secondsRemaining',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'seconds to respond',
                          style: TextStyle(fontSize: 12, color: Colors.white54),
                        ),
                      ],

                      const SizedBox(height: 28),

                      // Buttons
                      if (!isTerminated)
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: onDismiss,
                            icon: const Icon(Icons.directions_walk_rounded),
                            label: const Text("I'm Walking"),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFF59E0B),
                              foregroundColor: Colors.black87,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                      if (!isTerminated) const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: isTerminated ? onDismiss : onStop,
                          icon: Icon(
                            isTerminated
                                ? Icons.check_rounded
                                : Icons.stop_rounded,
                          ),
                          label: Text(
                            isTerminated ? 'Dismiss' : 'Stop Session',
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: BorderSide(
                              color: Colors.white.withOpacity(0.3),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Keeps a PageView child alive so state isn't lost on tab switch
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});
  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// ── Invasion Alert Card ────────────────────────────────────────────────────────
/// Persistent overlay shown on the map when the current user is actively
/// invading another player's territory.
class _InvasionAlertCard extends StatelessWidget {
  final String targetUsername;
  final VoidCallback onDismiss;

  const _InvasionAlertCard({
    required this.targetUsername,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF7F1D1D), Color(0xFF92400E)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: const Color(0xFFFF6B00).withOpacity(0.60),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFEF4444).withOpacity(0.35),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Pulsing sword icon
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: SvgPicture.asset(
                  'assets/security-fight.svg',
                  height: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Invading Territory!',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      'You are in $targetUsername\'s zone — battle live on map',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.85),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Dismiss (walk away) button
              GestureDetector(
                onTap: onDismiss,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white.withOpacity(0.30)),
                  ),
                  child: const Text(
                    'OK',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Danger Invasion Overlay ───────────────────────────────────────────────────
/// Full-screen semi-transparent red pulsing vignette shown whenever the current
/// user physically steps inside an enemy territory polygon.
/// Completely non-interactive (IgnorePointer) so map gestures still work.
class _DangerInvasionOverlay extends StatefulWidget {
  final double health; // 0.0 – 1.0 (kept for pulse intensity)
  final int hearts; // discrete hearts remaining (0..2)
  final int maxHearts; // total hearts (2)
  final int bombCount; // number of bombs triggered

  const _DangerInvasionOverlay({
    this.health = 1.0,
    this.hearts = 2,
    this.maxHearts = 2,
    this.bombCount = 0,
  });

  @override
  State<_DangerInvasionOverlay> createState() => _DangerInvasionOverlayState();
}

class _DangerInvasionOverlayState extends State<_DangerInvasionOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    // Heartbeat: quick ramp-up (300 ms), slow fade-out (600 ms), pause via curve
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulse = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final t = _pulse.value; // 0.0 → 1.0
          return Stack(
            children: [
              // ── Red vignette border around screen edges ──────────────────
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.center,
                      radius: 1.0,
                      colors: [
                        Colors.transparent,
                        const Color(0xFFEF4444).withOpacity(
                          0.10 + 0.45 * t, // pulses 0.10 → 0.55
                        ),
                      ],
                      stops: const [0.45, 1.0],
                    ),
                  ),
                ),
              ),
              // ── Thin red border frame that pulses ────────────────────────
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(
                        0xFFEF4444,
                      ).withOpacity(0.30 + 0.55 * t),
                      width: 3.0 + 3.0 * t,
                    ),
                    borderRadius: BorderRadius.circular(0),
                  ),
                ),
              ),
              // ── danger-dead.svg + label at top-center ────────────────────
              Positioned(
                top: 90,
                left: 0,
                right: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Pulsing glow circle behind icon
                    Container(
                      width: 64 + 8 * t,
                      height: 64 + 8 * t,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(
                          0xFFEF4444,
                        ).withOpacity(0.18 + 0.22 * t),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFFEF4444,
                            ).withOpacity(0.35 + 0.40 * t),
                            blurRadius: 20 + 14 * t,
                            spreadRadius: 4 + 6 * t,
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(12),
                      child: SvgPicture.asset(
                        'assets/danger-dead.svg',
                        // no colorFilter — preserve the SVG's natural colours
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Warning label
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(
                          0xFFEF4444,
                        ).withOpacity(0.55 + 0.30 * t),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFEF4444).withOpacity(0.4),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.warning_rounded,
                            color: Colors.white.withOpacity(0.90 + 0.10 * t),
                            size: 14,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'ENEMY TERRITORY',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.90 + 0.10 * t),
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Bomb badge (shown if territory is armed)
                    if (widget.bombCount > 0) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF1A1A2E,
                          ).withOpacity(0.75 + 0.20 * t),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0xFFEF4444).withOpacity(0.5),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SvgPicture.asset(
                              'assets/explosive-bomb.svg',
                              width: 14,
                              height: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${widget.bombCount} BOMB${widget.bombCount > 1 ? 'S' : ''} TRIGGERED  •  -30 TOPAZ',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // ── Hearts display at bottom of screen ──────────────────────
              Positioned(
                bottom: 120,
                left: 24,
                right: 24,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'HEARTS',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.0,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(widget.maxHearts, (i) {
                        final isFilled = i < widget.hearts;
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Transform.scale(
                            scale: isFilled ? 1.0 + 0.15 * t : 0.85,
                            child: Icon(
                              isFilled ? Icons.favorite : Icons.favorite_border,
                              color: isFilled
                                  ? const Color(0xFFEF4444)
                                  : Colors.white24,
                              size: 36,
                              shadows: isFilled
                                  ? [
                                      Shadow(
                                        color: const Color(
                                          0xFFEF4444,
                                        ).withOpacity(0.6 + 0.3 * t),
                                        blurRadius: 12 + 8 * t,
                                      ),
                                    ]
                                  : null,
                            ),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ── Bomb Explosion Overlay ────────────────────────────────────────────────────
/// Full-screen dramatic overlay shown the moment bomb damage is applied.
/// Shows explosion SVG, BOOM text, damage summary, and auto-dismisses.
class _BombExplosionOverlay extends StatefulWidget {
  final int bombCount;
  final int topazPenalty;

  const _BombExplosionOverlay({
    required this.bombCount,
    required this.topazPenalty,
  });

  @override
  State<_BombExplosionOverlay> createState() => _BombExplosionOverlayState();
}

class _BombExplosionOverlayState extends State<_BombExplosionOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..forward();
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut);
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Opacity(
          opacity: _fade.value.clamp(0.0, 1.0),
          child: Container(
            color: Colors.black.withOpacity(0.80),
            child: Stack(
              children: [
                // Fire-orange radial burst behind the explosion icon
                Center(
                  child: Transform.scale(
                    scale: _scale.value,
                    child: Container(
                      width: 280,
                      height: 280,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            const Color(0xFFFF6B00).withOpacity(0.70),
                            const Color(0xFFEF4444).withOpacity(0.35),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.5, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
                // Explosion SVG centred
                Center(
                  child: Transform.scale(
                    scale: _scale.value,
                    child: SvgPicture.asset(
                      'assets/explosion-bomb.svg',
                      width: 180,
                      height: 180,
                    ),
                  ),
                ),
                // BOOM text above icon
                Positioned(
                  top: MediaQuery.of(context).size.height * 0.18,
                  left: 0,
                  right: 0,
                  child: Transform.scale(
                    scale: _scale.value,
                    child: Text(
                      '💥  BOOM!',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 52,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                        shadows: [
                          Shadow(color: Color(0xFFFF6B00), blurRadius: 24),
                        ],
                      ),
                    ),
                  ),
                ),
                // Damage summary below icon
                Positioned(
                  bottom: MediaQuery.of(context).size.height * 0.22,
                  left: 24,
                  right: 24,
                  child: Opacity(
                    opacity: _fade.value,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEF4444).withOpacity(0.20),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: const Color(0xFFEF4444).withOpacity(0.50),
                              width: 1.5,
                            ),
                          ),
                          child: Column(
                            children: [
                              Text(
                                'You triggered ${widget.bombCount} '
                                'bomb${widget.bombCount == 1 ? '' : 's'}!',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (widget.topazPenalty > 0) ...[
                                const SizedBox(height: 6),
                                Text(
                                  '–${widget.topazPenalty} ⚡ Topaz penalty',
                                  style: const TextStyle(
                                    color: Color(0xFFFCD34D),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _GadgetsHUD — compact gadget panel shown during tracking
// ─────────────────────────────────────────────────────────────────────────────

class _GadgetsHUD extends StatelessWidget {
  final bool scanActive;
  final bool isScanLoading;
  final int scannerDockCount;
  final int defuseGunCount;
  final int scannedBombCount;
  final int scanSecondsRemaining;
  final VoidCallback? onScan; // null when unavailable

  const _GadgetsHUD({
    required this.scanActive,
    required this.isScanLoading,
    required this.scannerDockCount,
    required this.defuseGunCount,
    required this.scannedBombCount,
    required this.scanSecondsRemaining,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF0891B2);
    const emerald = Color(0xFF059669);
    final isUrgent = scanActive && scanSecondsRemaining <= 5;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 210),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF0D0D1A).withOpacity(0.82),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scanActive
                  ? (isUrgent
                      ? const Color(0xFFEF4444).withOpacity(0.7)
                      : emerald.withOpacity(0.6))
                  : cyan.withOpacity(0.4),
              width: 1.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.asset('assets/dog.svg', width: 16, height: 16),
                  const SizedBox(width: 6),
                  const Text(
                    'GADGETS',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  if (scanActive) ...[
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isUrgent
                            ? const Color(0xFFEF4444).withOpacity(0.25)
                            : emerald.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${scanSecondsRemaining}s',
                        style: TextStyle(
                          color: isUrgent ? const Color(0xFFEF4444) : const Color(0xFF34D399),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),

              // Scanner Dock row
              if (!scanActive) ...[
                GestureDetector(
                  onTap: onScan,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(
                      color: onScan != null
                          ? cyan.withOpacity(0.2)
                          : Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: onScan != null
                            ? cyan.withOpacity(0.5)
                            : Colors.white12,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isScanLoading)
                          const SizedBox(
                            width: 14, height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        else
                          const Icon(Icons.radar, size: 14, color: Colors.white70),
                        const SizedBox(width: 7),
                        Text(
                          isScanLoading
                              ? 'Scanning...'
                              : (scannerDockCount > 0
                                    ? 'Scan Territory ($scannerDockCount)'
                                    : 'No Docks'),
                          style: TextStyle(
                            color: onScan != null ? Colors.white : Colors.white38,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ] else ...[
                // Scan active: show countdown + result
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.radar, size: 14, color: Color(0xFF34D399)),
                    const SizedBox(width: 6),
                    Text(
                      scannedBombCount > 0
                          ? '$scannedBombCount bomb${scannedBombCount == 1 ? '' : 's'} found!'
                          : 'Area is clear',
                      style: TextStyle(
                        color: scannedBombCount > 0
                            ? const Color(0xFFFCD34D)
                            : const Color(0xFF34D399),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                if (scannedBombCount > 0) ...[
                  const SizedBox(height: 5),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SvgPicture.asset('assets/lasergun.svg', width: 12, height: 12),
                      const SizedBox(width: 5),
                      Text(
                        defuseGunCount > 0
                            ? 'Tap pin to defuse ($defuseGunCount)'
                            : 'No Defuse Guns',
                        style: TextStyle(
                          color: defuseGunCount > 0
                              ? const Color(0xFF6EE7B7)
                              : Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}