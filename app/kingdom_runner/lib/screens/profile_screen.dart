import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/territory_provider.dart';
import '../providers/theme_provider.dart';
import '../theme/app_theme.dart';
import '../models/user.dart';
import '../utils/format_utils.dart';
import 'login_screen.dart';
import 'shop_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _isLoading = false;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _refreshData();
    // Refresh every second so countdowns are live.
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshData() async {
    setState(() => _isLoading = true);
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final territoryProvider = Provider.of<TerritoryProvider>(
      context,
      listen: false,
    );

    await Future.wait([
      authProvider.loadCurrentUser(),
      territoryProvider.loadTerritories(),
      territoryProvider.loadInvasions(),
    ]);

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final authProvider = Provider.of<AuthProvider>(context);
    final territoryProvider = Provider.of<TerritoryProvider>(context);
    final user = authProvider.currentUser;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (user == null) {
      return const Scaffold(body: Center(child: Text('User not found')));
    }

    final userTerritories = territoryProvider.getTerritoriesByUser(user.id);
    final totalArea = territoryProvider.getTotalAreaByUser(user.id);

    // Prune any expired attacks on every build (converts expired → conquests)
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => territoryProvider.processExpiredAttacks(),
    );

    // Geometry-based overlap detection — works on BOTH attacker and defender devices
    // without needing backend sync. Shows alert any time two territory hulls touch.
    // Overlaps where the user already tapped “Defend” are suppressed for 24 h.
    final overlaps = territoryProvider
        .getMyOverlappingTerritories(user.id)
        .where(
          (info) => !territoryProvider.isRecentlyReclaimed(info.myTerritoryId),
        )
        .toList();

    // Attacked territories that belong to the current user (tracked locally)
    final attackedOwned = userTerritories
        .where((t) => territoryProvider.isUnderAttack(t.id))
        .toList();

    // Territories the current user has permanently LOST (conquered by attacker)
    final conqueredByEnemy = userTerritories
        .where((t) => territoryProvider.conquests.containsKey(t.id))
        .toList();

    // Territories the current user has permanently WON from others
    final myVictories = territoryProvider.conquests.values
        .where(
          (c) => territoryProvider.territories.any(
            (t) => t.id == c.attackerTerritoryId && t.userId == user.id,
          ),
        )
        .toList();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Profile'),
        actions: [
          IconButton(
            icon: _isLoading
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  )
                : const Icon(Icons.refresh),
            onPressed: _isLoading ? null : _refreshData,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await authProvider.logout();
              if (context.mounted) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                );
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildProfileCard(context, user, theme),
              const SizedBox(height: 16),
              // ── Current Mode card (Attack / Defend / Idle) ──
              _buildCurrentModeCard(
                context, theme, territoryProvider, overlaps,
              ),
              const SizedBox(height: 16),
              // ── Server-backed invasion cards ──
              if (territoryProvider.myActiveDefenses.isNotEmpty) ...[
                _buildServerDefenseCard(
                  context, theme, territoryProvider,
                ),
                const SizedBox(height: 16),
              ],
              if (territoryProvider.myActiveAttacks.isNotEmpty) ...[
                _buildServerAttackCard(
                  context, theme, territoryProvider,
                ),
                const SizedBox(height: 16),
              ],
              // ── Geometry-driven alert (always visible when territories overlap)
              if (overlaps.isNotEmpty) ...[
                _buildOverlapAlertCard(
                  context,
                  theme,
                  overlaps,
                  territoryProvider,
                ),
                const SizedBox(height: 16),
              ],
              // ── Tracked attack card (local, attacker's device only)
              if (attackedOwned.isNotEmpty) ...[
                _buildAttackWarningsCard(
                  context,
                  theme,
                  attackedOwned,
                  territoryProvider,
                ),
                const SizedBox(height: 16),
              ],
              if (conqueredByEnemy.isNotEmpty) ...[
                _buildConquestLostCard(
                  context,
                  theme,
                  conqueredByEnemy,
                  territoryProvider,
                ),
                const SizedBox(height: 16),
              ],
              if (myVictories.isNotEmpty) ...[
                _buildVictoryCard(context, theme, myVictories),
                const SizedBox(height: 16),
              ],
              _buildStatsCard(
                context,
                user,
                theme,
                userTerritories.length,
                totalArea,
              ),
              const SizedBox(height: 16),
              _buildSettingsCard(context, theme, isDark),
              const SizedBox(
                height: 120,
              ), // space so last card scrolls above dock
            ],
          ),
        ),
      ),
    );
  }
  // ─── Current Mode card (Attack / Defend / Idle) ────────────────────────────

  Widget _buildCurrentModeCard(
    BuildContext context,
    ThemeData theme,
    TerritoryProvider territoryProvider,
    List<OverlapInfo> overlaps,
  ) {
    final mode = territoryProvider.currentMode;

    final IconData icon;
    final String title;
    final String subtitle;
    final Color accentColor;

    switch (mode) {
      case 'attack':
        icon = Icons.sports_martial_arts;
        title = '🗡️ ATTACK MODE';
        final attacks = territoryProvider.myActiveAttacks;
        subtitle = attacks.isNotEmpty
            ? 'Invading ${attacks.first['defenderUsername']}\'s territory'
            : 'You are in attack mode';
        accentColor = const Color(0xFFEF4444);
        break;
      case 'defend':
        icon = Icons.shield;
        title = '🛡️ DEFEND MODE';
        final defenses = territoryProvider.myActiveDefenses;
        subtitle = defenses.isNotEmpty
            ? '${defenses.first['attackerUsername']} is invading your territory!'
            : 'Your territory is under attack';
        accentColor = const Color(0xFFFF6B00);
        break;
      default:
        if (overlaps.isNotEmpty) {
          icon = Icons.warning_amber_rounded;
          title = '⚔️ Territory Contested';
          subtitle = '${overlaps.length} territory overlap${overlaps.length > 1 ? 's' : ''} detected';
          accentColor = const Color(0xFFFF6B00);
        } else {
          icon = Icons.landscape;
          title = '⚔️ Kingdom Status';
          subtitle = 'No active invasions';
          accentColor = const Color(0xFF16A34A);
        }
    }

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            accentColor.withOpacity(0.12),
            accentColor.withOpacity(0.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accentColor.withOpacity(0.6), width: 1.8),
        boxShadow: [
          BoxShadow(
            color: accentColor.withOpacity(0.15),
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 26, color: accentColor),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: accentColor,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.textTheme.bodySmall?.color?.withOpacity(0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Server-backed Defense card (defender sees these) ─────────────────────

  Widget _buildServerDefenseCard(
    BuildContext context,
    ThemeData theme,
    TerritoryProvider territoryProvider,
  ) {
    final defenses = territoryProvider.myActiveDefenses;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF7F1D1D).withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFFF6B00).withOpacity(0.6),
          width: 1.5,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6B00).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.shield,
                  size: 18,
                  color: Color(0xFFFF6B00),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '🛡️ Defend Your Territory!',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFFFF6B00),
                      ),
                    ),
                    Text(
                      'Walk back to reclaim before time runs out',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...defenses.map((invasion) {
            final timeRemainingMs = (invasion['timeRemainingMs'] as num?)?.toInt() ?? 0;
            final remaining = Duration(milliseconds: timeRemainingMs);
            final hours = remaining.inHours;
            final minutes = remaining.inMinutes.remainder(60);
            final seconds = remaining.inSeconds.remainder(60);
            final isUrgent = hours < 3;
            final countdownColor = isUrgent
                ? const Color(0xFFEF4444)
                : const Color(0xFFF59E0B);
            final invasionId = invasion['_id'] ?? invasion['id'] ?? '';

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: countdownColor.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  const Text('⚡', style: TextStyle(fontSize: 22)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Invaded by ${invasion['attackerUsername'] ?? 'Unknown'}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.timer_outlined,
                              size: 13,
                              color: countdownColor,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              "${hours}h ${minutes.toString().padLeft(2, '0')}m "
                              "${seconds.toString().padLeft(2, '0')}s remaining",
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: countdownColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () async {
                          final success = await territoryProvider
                              .defendInvasionOnBackend(invasionId);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  success
                                      ? '🛡️ Territory defended successfully!'
                                      : '❌ Failed to defend territory',
                                ),
                                backgroundColor:
                                    success ? Colors.green : Colors.red,
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.shield, size: 14),
                        label: const Text(
                          'Defend',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF6B00),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      // ☢️ Nuke button — only shown when user has nukes
                      Builder(builder: (_) {
                        final auth = Provider.of<AuthProvider>(context, listen: false);
                        final nukes = auth.currentUser?.nukeInventory ?? 0;
                        if (nukes < 1) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('☢️ Use Nuke?'),
                                  content: const Text(
                                    'This will destroy the invader\'s nearby territories! '
                                    'This action cannot be undone.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, false),
                                      child: const Text('Cancel'),
                                    ),
                                    ElevatedButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFFDC2626),
                                      ),
                                      child: const Text('NUKE IT',
                                          style: TextStyle(color: Colors.white)),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed != true) return;
                              try {
                                final result = await auth.apiService.useNuke(invasionId);
                                await auth.loadCurrentUser();
                                await territoryProvider.loadInvasions();
                                await territoryProvider.loadTerritories();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '☢️ NUKED! Destroyed ${result['destroyedCount']} '
                                        'enemy territories (${result['destroyedArea']}m²)',
                                      ),
                                      backgroundColor: const Color(0xFFDC2626),
                                    ),
                                  );
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('❌ ${e.toString().replaceFirst("Exception: ", "")}'),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              }
                            },
                            icon: SvgPicture.asset('assets/nuke.svg', width: 13, height: 13),
                            label: Text(
                              'Nuke ($nukes)',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFDC2626),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ─── Server-backed Attack card (attacker sees these) ──────────────────────

  Widget _buildServerAttackCard(
    BuildContext context,
    ThemeData theme,
    TerritoryProvider territoryProvider,
  ) {
    final attacks = territoryProvider.myActiveAttacks;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF4A0404).withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFEF4444).withOpacity(0.5),
          width: 1.5,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.sports_martial_arts,
                  size: 18,
                  color: Color(0xFFEF4444),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '🗡️ Active Invasions',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFFEF4444),
                      ),
                    ),
                    Text(
                      'Territories you are attacking',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...attacks.map((invasion) {
            final timeRemainingMs = (invasion['timeRemainingMs'] as num?)?.toInt() ?? 0;
            final remaining = Duration(milliseconds: timeRemainingMs);
            final hours = remaining.inHours;
            final minutes = remaining.inMinutes.remainder(60);

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFFEF4444).withOpacity(0.3),
                ),
              ),
              child: Row(
                children: [
                  const Text('🗺️', style: TextStyle(fontSize: 22)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${invasion['defenderUsername'] ?? 'Unknown'}\'s territory',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '⏱ ${hours}h ${minutes.toString().padLeft(2, '0')}m until conquest',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: hours < 3
                                ? const Color(0xFF16A34A)
                                : const Color(0xFFF59E0B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Text('⚔️', style: TextStyle(fontSize: 20)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ─── Geometry-based overlap alert (always shown when hulls collide) ────────

  Widget _buildOverlapAlertCard(
    BuildContext context,
    ThemeData theme,
    List<OverlapInfo> overlaps,
    TerritoryProvider territoryProvider,
  ) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF7F1D1D).withOpacity(0.13),
            const Color(0xFF92400E).withOpacity(0.10),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFFF6B00).withOpacity(0.65),
          width: 1.8,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF6B00).withOpacity(0.18),
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6B00).withOpacity(0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SvgPicture.asset(
                  'assets/security-fight.svg',
                  height: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '⚠️ Territory Under Siege!',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFFFF6B00),
                      ),
                    ),
                    Text(
                      'Another player\'s territory overlaps yours',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.textTheme.bodySmall?.color?.withOpacity(
                          0.75,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Divider(color: const Color(0xFFFF6B00).withOpacity(0.25), height: 20),
          ...overlaps.map((info) {
            final matchedAttack = territoryProvider.attacks[info.myTerritoryId];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  const Text('🗺️', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${info.theirUsername} is in your zone',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (matchedAttack != null)
                          Builder(
                            builder: (_) {
                              final rem = matchedAttack.timeRemaining;
                              final h = rem.inHours;
                              final m = rem.inMinutes % 60;
                              return Text(
                                '⏱ ${h}h ${m.toString().padLeft(2, '0')}m to reclaim',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: h < 3
                                      ? const Color(0xFFEF4444)
                                      : const Color(0xFFF59E0B),
                                  fontWeight: FontWeight.bold,
                                ),
                              );
                            },
                          )
                        else
                          Text(
                            'Battle zone active on the map',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: const Color(0xFFFF6B00),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () {
                          territoryProvider.reclaimTerritory(info.myTerritoryId);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                '🏃 Walk back and defend your territory!',
                              ),
                              backgroundColor: Colors.orange,
                            ),
                          );
                        },
                        icon: const Icon(Icons.shield, size: 13),
                        label: const Text(
                          'Defend',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF6B00),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      // ☢️ Nuke button — always visible when user has nukes
                      Builder(builder: (_) {
                        final auth = Provider.of<AuthProvider>(context, listen: false);
                        final nukes = auth.currentUser?.nukeInventory ?? 0;
                        if (nukes < 1) return const SizedBox.shrink();
                        // Check for a matching server invasion (optional)
                        final matchingInvasion = territoryProvider.myActiveDefenses
                            .where((inv) =>
                                inv['territoryId'] == info.myTerritoryId)
                            .toList();
                        final invasionId = matchingInvasion.isNotEmpty
                            ? (matchingInvasion.first['_id'] ??
                                matchingInvasion.first['id'] ??
                                '')
                            : '';
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: ElevatedButton.icon(
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('☢️ Use Nuke?'),
                                  content: const Text(
                                    'This will destroy the invader\'s nearby territories! '
                                    'This action cannot be undone.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx, false),
                                      child: const Text('Cancel'),
                                    ),
                                    ElevatedButton(
                                      onPressed: () => Navigator.pop(ctx, true),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFFDC2626),
                                      ),
                                      child: const Text('NUKE IT',
                                          style: TextStyle(color: Colors.white)),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed != true) return;
                              try {
                                // Use invasion-based nuke if available, otherwise territory-based
                                final Map<String, dynamic> result;
                                if (invasionId.toString().isNotEmpty) {
                                  result = await auth.apiService.useNuke(invasionId);
                                } else {
                                  result = await auth.apiService.useNukeByTerritory(
                                    info.myTerritoryId,
                                    enemyUsername: info.theirUsername,
                                  );
                                }
                                await auth.loadCurrentUser();
                                await territoryProvider.loadInvasions();
                                await territoryProvider.loadTerritories();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '☢️ NUKED! Destroyed ${result['destroyedCount']} '
                                        'enemy territories (${result['destroyedArea']}m²)',
                                      ),
                                      backgroundColor: const Color(0xFFDC2626),
                                    ),
                                  );
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '❌ ${e.toString().replaceFirst("Exception: ", "")}',
                                      ),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              }
                            },
                            icon: SvgPicture.asset(
                              'assets/nuke.svg',
                              width: 13,
                              height: 13,
                            ),
                            label: Text(
                              'Nuke ($nukes)',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFDC2626),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ─── Attack warnings card ─────────────────────────────────────────────────

  Widget _buildAttackWarningsCard(
    BuildContext context,
    ThemeData theme,
    List territories,
    TerritoryProvider territoryProvider,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF7F1D1D).withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFEF4444).withOpacity(0.5),
          width: 1.5,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: Color(0xFFEF4444),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '⚠️ Territory Under Attack!',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFFEF4444),
                      ),
                    ),
                    Text(
                      'Reclaim before the timer expires',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...territories.map((territory) {
            final attack = territoryProvider.attacks[territory.id];
            if (attack == null) return const SizedBox.shrink();
            final remaining = attack.timeRemaining;
            final hours = remaining.inHours;
            final minutes = remaining.inMinutes.remainder(60);
            final seconds = remaining.inSeconds.remainder(60);
            final isUrgent = remaining.inHours < 3;
            final countdownColor = isUrgent
                ? const Color(0xFFEF4444)
                : const Color(0xFFF59E0B);

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: countdownColor.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  const Text('⚡', style: TextStyle(fontSize: 22)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "${territory.username}'s territory",
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Attacked by ${attack.attackerUsername}',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.timer_outlined,
                              size: 13,
                              color: countdownColor,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              "${hours}h ${minutes.toString().padLeft(2, '0')}m "
                              "${seconds.toString().padLeft(2, '0')}s remaining",
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: countdownColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      territoryProvider.reclaimTerritory(territory.id);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            '✅ Territory reclaim started! Walk back to defend it.',
                          ),
                          backgroundColor: Colors.green,
                        ),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEF4444),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      'Reclaim',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ─── Territory lost (conquered) card ─────────────────────────────────────

  Widget _buildConquestLostCard(
    BuildContext context,
    ThemeData theme,
    List territories,
    TerritoryProvider territoryProvider,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF4A0404).withOpacity(0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF991B1B).withOpacity(0.6),
          width: 1.5,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF991B1B).withOpacity(0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('💀', style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '🏳️ Territory Conquered!',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF991B1B),
                      ),
                    ),
                    Text(
                      'The overlapping area now belongs to the attacker',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...territories.map((territory) {
            final conquest = territoryProvider.conquests[territory.id];
            if (conquest == null) return const SizedBox.shrink();
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF991B1B).withOpacity(0.4),
                ),
              ),
              child: Row(
                children: [
                  SvgPicture.asset(
                    'assets/security-fight.svg',
                    height: 24,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          territory.username,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Intersection taken by ${conquest.attackerUsername}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF991B1B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: () {
                      territoryProvider.reclaimTerritory(territory.id);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            '🏃 Walk back to reclaim your territory!',
                          ),
                          backgroundColor: Colors.orange,
                        ),
                      );
                    },
                    icon: const Icon(Icons.flag, size: 14),
                    label: const Text('Retake', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF991B1B),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ─── Victory card (territories I conquered) ───────────────────────────────

  Widget _buildVictoryCard(
    BuildContext context,
    ThemeData theme,
    List<TerritoryConquest> victories,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF14532D).withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF16A34A).withOpacity(0.5),
          width: 1.5,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF16A34A).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('🏆', style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '🎉 Battle Won!',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: const Color(0xFF16A34A),
                      ),
                    ),
                    Text(
                      'You conquered the intersection zone',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...victories.map((conquest) {
            final conqueredAt = conquest.conqueredAt;
            final ago = DateTime.now().difference(conqueredAt);
            final agoText = ago.inHours > 0
                ? '${ago.inHours}h ago'
                : '${ago.inMinutes}m ago';
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF16A34A).withOpacity(0.4),
                ),
              ),
              child: Row(
                children: [
                  const Text('🗺️', style: TextStyle(fontSize: 22)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Intersection zone captured',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Conquered $agoText',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF16A34A),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Text('✅', style: TextStyle(fontSize: 20)),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ─── Profile card ──────────────────────────────────────────────────────────

  Widget _buildProfileCard(BuildContext context, User user, ThemeData theme) {
    return _card(
      theme,
      child: Column(
        children: [
          Hero(
            tag: 'profile_avatar',
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: theme.colorScheme.primary, width: 2),
              ),
              child: user.avatarPath != null
                  ? CircleAvatar(
                      radius: 40,
                      backgroundImage: AssetImage(user.avatarPath!),
                      backgroundColor: theme.dividerColor,
                    )
                  : CircleAvatar(
                      radius: 40,
                      backgroundColor: theme.colorScheme.primary.withOpacity(
                        0.15,
                      ),
                      child: Text(
                        user.username[0].toUpperCase(),
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            user.username,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(user.email, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 14),
          // ── Topaz balance chip ─────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF6D28D9), Color(0xFF7C3AED)],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(50),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF7C3AED).withOpacity(0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SvgPicture.asset(
                  'assets/coin-currency.svg',
                  height: 20,
                ),
                const SizedBox(width: 6),
                Text(
                  '${user.topazCoins} Topaz',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // ── Visit Armory shortcut ─────────────────────────────────
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ShopScreen()),
            ),
            icon: SvgPicture.asset(
              'assets/shield-defense.svg',
              width: 16,
              height: 16,
            ),
            label: const Text('Kingdom Armory'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF7B2FBE),
              side: const BorderSide(color: Color(0xFF7B2FBE), width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(50),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 8,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Statistics card ───────────────────────────────────────────────────────

  Widget _buildStatsCard(
    BuildContext context,
    User user,
    ThemeData theme,
    int territoriesCount,
    double totalArea,
  ) {
    return _card(
      theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeader(theme, Icons.bar_chart, 'Statistics'),
          const SizedBox(height: 12),
          _buildStatRow(
            theme,
            'Total Distance',
            formatDistance(user.totalDistance),
            Icons.directions_run,
          ),
          const SizedBox(height: 8),
          _buildStatRow(
            theme,
            'Kingdom Size',
            formatArea(totalArea),
            Icons.terrain,
          ),
          const SizedBox(height: 8),
          _buildStatRow(theme, 'Territories', '$territoriesCount', Icons.map),
          const SizedBox(height: 8),
          _buildStatRow(
            theme,
            'Activity Streak',
            '${user.activityStreak} days',
            Icons.local_fire_department,
          ),
          const SizedBox(height: 8),
          // Topaz coins row with SVG icon
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF7C3AED).withOpacity(0.08),
                  const Color(0xFF6D28D9).withOpacity(0.05),
                ],
              ),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: const Color(0xFF7C3AED).withOpacity(0.3),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C3AED).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SvgPicture.asset(
                    'assets/coin-currency.svg',
                    height: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Topaz Balance',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  '${user.topazCoins}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    color: Color(0xFF7C3AED),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Settings card ─────────────────────────────────────────────────────────

  Widget _buildSettingsCard(
    BuildContext context,
    ThemeData theme,
    bool isDark,
  ) {
    return _card(
      theme,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardHeader(theme, Icons.settings, 'Settings'),
          const SizedBox(height: 8),
          Consumer<ThemeProvider>(
            builder: (_, themeProvider, __) => _toggleTile(
              theme: theme,
              isDark: isDark,
              icon: themeProvider.isDarkMode
                  ? Icons.dark_mode
                  : Icons.light_mode,
              title: 'Dark Mode',
              subtitle: 'Switch to dark theme',
              value: themeProvider.isDarkMode,
              onChanged: (_) => themeProvider.toggleTheme(),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Shared helpers ────────────────────────────────────────────────────────

  /// White-bg card container matching `bg-card / text-card-foreground`.
  Widget _card(ThemeData theme, {required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }

  /// Left-aligned section header with icon.
  Widget _cardHeader(ThemeData theme, IconData icon, String title) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: theme.colorScheme.primary),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildStatRow(
    ThemeData theme,
    String label,
    String value,
    IconData icon,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// Settings toggle tile — active = bg-primary, inactive = bg-input.
  Widget _toggleTile({
    required ThemeData theme,
    required bool isDark,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final primary = theme.colorScheme.primary;
    final inputColor = isDark ? AppColors.darkInput : AppColors.input;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(subtitle, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: Colors.white,
            activeTrackColor: primary,
            inactiveThumbColor: Colors.white,
            inactiveTrackColor: inputColor,
          ),
        ],
      ),
    );
  }
}
