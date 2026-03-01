const User = require('../models/User');
const Territory = require('../models/Territory');
const Invasion = require('../models/Invasion');

const BOMB_PRICE = 50; // Topaz coins
const MAX_BOMBS_PER_TERRITORY = 3;
const BOMB_TOPAZ_PENALTY = 30; // Deducted from invader per bomb
const BOMB_HEALTH_DAMAGE = 50; // % health per bomb (2 bombs = 100% = killed)
const SCANNER_DOCK_PRICE = 80; // Reveals bomb positions on enemy territory
const DEFUSE_GUN_PRICE = 120;  // Permanently disables one enemy bomb
const NUKE_PRICE = 10000;      // Nuclear strike — destroys invader + their territory

// ── Buy a bomb ───────────────────────────────────────────────────────────────
exports.buyBomb = async (req, res) => {
  try {
    const user = await User.findById(req.user._id);
    if (!user) return res.status(404).json({ error: 'User not found' });

    if (user.topazCoins < BOMB_PRICE) {
      return res.status(400).json({
        error: `Not enough Topaz. Need ${BOMB_PRICE}, have ${user.topazCoins}.`,
      });
    }

    user.topazCoins -= BOMB_PRICE;
    user.inventory = user.inventory || {};
    user.inventory.bombs = (user.inventory.bombs || 0) + 1;
    user.markModified('inventory');
    await user.save();

    res.json({
      message: 'Bomb purchased!',
      bombsOwned: user.inventory.bombs,
      topazCoins: user.topazCoins,
    });
  } catch (err) {
    console.error('buyBomb error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

// ── Place a bomb on one of your territories ──────────────────────────────────
exports.placeBomb = async (req, res) => {
  try {
    const { territoryId } = req.body;
    if (!territoryId) return res.status(400).json({ error: 'territoryId required' });

    const territory = await Territory.findById(territoryId);
    if (!territory) return res.status(404).json({ error: 'Territory not found' });
    if (territory.userId.toString() !== req.user._id.toString()) {
      return res.status(403).json({ error: 'Not your territory' });
    }
    if ((territory.bombCount || 0) >= MAX_BOMBS_PER_TERRITORY) {
      return res.status(400).json({
        error: `Max ${MAX_BOMBS_PER_TERRITORY} bombs per territory`,
      });
    }

    const user = await User.findById(req.user._id);
    if (!user || (user.inventory?.bombs || 0) < 1) {
      return res.status(400).json({ error: 'No bombs in inventory' });
    }

    user.inventory.bombs -= 1;
    user.markModified('inventory');
    territory.bombCount = (territory.bombCount || 0) + 1;

    // Store the placement position if provided
    const { lat, lng } = req.body;
    if (lat != null && lng != null) {
      territory.bombPositions = territory.bombPositions || [];
      territory.bombPositions.push({ lat: parseFloat(lat), lng: parseFloat(lng) });
    }

    await Promise.all([user.save(), territory.save()]);

    res.json({
      message: 'Bomb placed!',
      bombCount: territory.bombCount,
      bombsOwned: user.inventory.bombs,
      bombPositions: territory.bombPositions || [],
    });
  } catch (err) {
    console.error('placeBomb error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

// ── Remove a bomb from one of your territories ───────────────────────────────
exports.removeBomb = async (req, res) => {
  try {
    const { territoryId } = req.body;
    if (!territoryId) return res.status(400).json({ error: 'territoryId required' });

    const territory = await Territory.findById(territoryId);
    if (!territory) return res.status(404).json({ error: 'Territory not found' });
    if (territory.userId.toString() !== req.user._id.toString()) {
      return res.status(403).json({ error: 'Not your territory' });
    }
    if ((territory.bombCount || 0) < 1) {
      return res.status(400).json({ error: 'No bombs on this territory' });
    }

    const user = await User.findById(req.user._id);
    territory.bombCount -= 1;
    user.inventory = user.inventory || {};
    user.inventory.bombs = (user.inventory.bombs || 0) + 1;
    user.markModified('inventory');

    // Remove specific position if provided, otherwise pop the last one
    const { lat, lng } = req.body;
    if (lat != null && lng != null && Array.isArray(territory.bombPositions)) {
      const idx = territory.bombPositions.findIndex(
        (p) => Math.abs(p.lat - parseFloat(lat)) < 0.000001 && Math.abs(p.lng - parseFloat(lng)) < 0.000001
      );
      if (idx !== -1) territory.bombPositions.splice(idx, 1);
      else territory.bombPositions.pop();
    } else if (Array.isArray(territory.bombPositions) && territory.bombPositions.length > 0) {
      territory.bombPositions.pop();
    }

    await Promise.all([user.save(), territory.save()]);

    res.json({
      message: 'Bomb retrieved',
      bombCount: territory.bombCount,
      bombsOwned: user.inventory.bombs,
      bombPositions: territory.bombPositions || [],
    });
  } catch (err) {
    console.error('removeBomb error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

// ── Apply bomb damage when someone invades an armed territory ─────────────────
// Called by the invader's device when it detects entry into armed territory.
exports.applyBombDamage = async (req, res) => {
  try {
    const { territoryId, lat, lng } = req.body;
    if (!territoryId) return res.status(400).json({ error: 'territoryId required' });

    const territory = await Territory.findById(territoryId);
    if (!territory) return res.status(404).json({ error: 'Territory not found' });

    const bombs = territory.bombCount || 0;
    if (bombs === 0) return res.json({ damage: 0, topazPenalty: 0, message: 'No bombs', bombCount: 0, bombPositions: [] });

    // Deduct topaz from invader (single bomb penalty — one bomb per trigger)
    const topazPenalty = BOMB_TOPAZ_PENALTY;
    const healthDamage = BOMB_HEALTH_DAMAGE;

    const invader = await User.findById(req.user._id);
    if (invader) {
      invader.topazCoins = Math.max(0, (invader.topazCoins || 0) - topazPenalty);
      await invader.save();
    }

    // Remove the specific detonated bomb from the territory
    if (lat != null && lng != null && Array.isArray(territory.bombPositions) && territory.bombPositions.length > 0) {
      const parsedLat = parseFloat(lat);
      const parsedLng = parseFloat(lng);
      const idx = territory.bombPositions.findIndex(
        p => Math.abs(p.lat - parsedLat) < 0.000001 && Math.abs(p.lng - parsedLng) < 0.000001
      );
      if (idx !== -1) territory.bombPositions.splice(idx, 1);
    }
    territory.bombCount = Math.max(0, (territory.bombCount || 0) - 1);
    await territory.save();

    res.json({
      damage: healthDamage,
      topazPenalty: topazPenalty,
      bombs: 1,
      topazRemaining: invader?.topazCoins ?? 0,
      bombCount: territory.bombCount,
      bombPositions: territory.bombPositions ?? [],
      message: `Bomb detonated! -${topazPenalty} Topaz!`,
    });
  } catch (err) {
    console.error('applyBombDamage error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

// ── Get current user's shop/inventory status ─────────────────────────────────
exports.getInventory = async (req, res) => {
  try {
    const user = await User.findById(req.user._id).lean();
    if (!user) return res.status(404).json({ error: 'User not found' });
    res.json({
      topazCoins: user.topazCoins || 0,
      inventory: {
        bombs: user.inventory?.bombs || 0,
        scannerDocks: user.inventory?.scannerDocks || 0,
        defuseGuns: user.inventory?.defuseGuns || 0,
        nukes: user.inventory?.nukes || 0,
      },
      bombPrice: BOMB_PRICE,
      scannerDockPrice: SCANNER_DOCK_PRICE,
      defuseGunPrice: DEFUSE_GUN_PRICE,
      nukePrice: NUKE_PRICE,
    });
  } catch (err) {
    console.error('getInventory error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

// ── Buy a Scanner Dock ────────────────────────────────────────────────────────
exports.buyScannerDock = async (req, res) => {
  try {
    const user = await User.findById(req.user._id);
    if (!user) return res.status(404).json({ error: 'User not found' });

    if (user.topazCoins < SCANNER_DOCK_PRICE) {
      return res.status(400).json({
        error: `Not enough Topaz. Need ${SCANNER_DOCK_PRICE}, have ${user.topazCoins}.`,
      });
    }

    user.topazCoins -= SCANNER_DOCK_PRICE;
    user.inventory = user.inventory || {};
    user.inventory.scannerDocks = (user.inventory.scannerDocks || 0) + 1;
    user.markModified('inventory');
    await user.save();

    res.json({
      message: 'Scanner Dock purchased!',
      scannerDocksOwned: user.inventory.scannerDocks,
      topazCoins: user.topazCoins,
    });
  } catch (err) {
    console.error('buyScannerDock error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

// ── Buy a Defuse Gun ──────────────────────────────────────────────────────────
exports.buyDefuseGun = async (req, res) => {
  try {
    const user = await User.findById(req.user._id);
    if (!user) return res.status(404).json({ error: 'User not found' });

    if (user.topazCoins < DEFUSE_GUN_PRICE) {
      return res.status(400).json({
        error: `Not enough Topaz. Need ${DEFUSE_GUN_PRICE}, have ${user.topazCoins}.`,
      });
    }

    user.topazCoins -= DEFUSE_GUN_PRICE;
    user.inventory = user.inventory || {};
    user.inventory.defuseGuns = (user.inventory.defuseGuns || 0) + 1;
    user.markModified('inventory');
    await user.save();

    res.json({
      message: 'Defuse Gun purchased!',
      defuseGunsOwned: user.inventory.defuseGuns,
      topazCoins: user.topazCoins,
    });
  } catch (err) {
    console.error('buyDefuseGun error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

// ── Activate scanner dock (deducts 1 from inventory) ─────────────────────────
exports.useScannerDock = async (req, res) => {
  try {
    const user = await User.findById(req.user._id);
    if (!user) return res.status(404).json({ error: 'User not found' });

    if ((user.inventory?.scannerDocks || 0) < 1) {
      return res.status(400).json({ error: 'No Scanner Docks in inventory' });
    }

    user.inventory.scannerDocks -= 1;
    user.markModified('inventory');
    await user.save();

    res.json({
      message: 'Scanner Dock activated!',
      scannerDocksOwned: user.inventory.scannerDocks,
    });
  } catch (err) {
    console.error('useScannerDock error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

// ── Defuse a specific bomb on an enemy territory ──────────────────────────────
// Called by the invader. Costs 1 Defuse Gun. Bomb is permanently destroyed.
exports.defuseBomb = async (req, res) => {
  try {
    const { territoryId, lat, lng } = req.body;
    if (!territoryId || lat == null || lng == null) {
      return res.status(400).json({ error: 'territoryId, lat and lng required' });
    }

    const invader = await User.findById(req.user._id);
    if (!invader) return res.status(404).json({ error: 'User not found' });

    if ((invader.inventory?.defuseGuns || 0) < 1) {
      return res.status(400).json({ error: 'No Defuse Guns in inventory' });
    }

    const territory = await Territory.findById(territoryId);
    if (!territory) return res.status(404).json({ error: 'Territory not found' });
    if ((territory.bombCount || 0) < 1) {
      return res.status(400).json({ error: 'No bombs on this territory' });
    }

    // Remove the specific bomb position
    const idx = (territory.bombPositions || []).findIndex(
      (p) =>
        Math.abs(p.lat - parseFloat(lat)) < 0.000001 &&
        Math.abs(p.lng - parseFloat(lng)) < 0.000001,
    );
    if (idx !== -1) territory.bombPositions.splice(idx, 1);
    territory.bombCount = Math.max(0, (territory.bombCount || 1) - 1);

    // Consume 1 defuse gun — bomb is DESTROYED, not returned to owner
    invader.inventory.defuseGuns -= 1;
    invader.markModified('inventory');

    await Promise.all([territory.save(), invader.save()]);

    res.json({
      message: 'Bomb defused!',
      bombCount: territory.bombCount,
      defuseGunsOwned: invader.inventory.defuseGuns,
    });
  } catch (err) {
    console.error('defuseBomb error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

// ── Buy a Nuke ──────────────────────────────────────────────────────────────
exports.buyNuke = async (req, res) => {
  try {
    const user = await User.findById(req.user._id);
    if (!user) return res.status(404).json({ error: 'User not found' });

    if (user.topazCoins < NUKE_PRICE) {
      return res.status(400).json({
        error: `Not enough Topaz. Need ${NUKE_PRICE}, have ${user.topazCoins}.`,
      });
    }

    user.topazCoins -= NUKE_PRICE;
    user.inventory = user.inventory || {};
    user.inventory.nukes = (user.inventory.nukes || 0) + 1;
    user.markModified('inventory');
    await user.save();

    res.json({
      message: 'Nuke purchased!',
      nukesOwned: user.inventory.nukes,
      topazCoins: user.topazCoins,
    });
  } catch (err) {
    console.error('buyNuke error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

// ── Use a Nuke (defender destroys invader's territory) ────────────────────────
// Requires an active invasion ID. Resolves the invasion and deactivates the
// attacker's territories that overlap with the defended territory.
exports.useNuke = async (req, res) => {
  try {
    const { invasionId } = req.body;
    if (!invasionId) {
      return res.status(400).json({ error: 'invasionId is required' });
    }

    // Validate the invasion exists and the user is the defender
    const invasion = await Invasion.findById(invasionId);
    if (!invasion) {
      return res.status(404).json({ error: 'Invasion not found' });
    }
    if (invasion.defenderId.toString() !== req.user._id.toString()) {
      return res.status(403).json({ error: 'Only the defender can use a nuke' });
    }
    if (invasion.status !== 'active') {
      return res.status(400).json({ error: `Invasion already ${invasion.status}` });
    }

    // Check nuke inventory
    const user = await User.findById(req.user._id);
    if (!user || (user.inventory?.nukes || 0) < 1) {
      return res.status(400).json({ error: 'No nukes in inventory' });
    }

    // Consume 1 nuke
    user.inventory.nukes -= 1;
    user.markModified('inventory');
    await user.save();

    // Resolve the invasion as "defended" (nuked)
    invasion.status = 'defended';
    invasion.resolvedAt = new Date();
    await invasion.save();

    // Destroy all attacker territories that overlap the defended territory
    // For simplicity, we deactivate ALL territories owned by the attacker
    // that are near the defended territory.
    const attackerTerritories = await Territory.find({
      userId: invasion.attackerId,
      isActive: true,
    });

    let destroyedCount = 0;
    let destroyedArea = 0;

    for (const t of attackerTerritories) {
      // Check if any point of the attacker's territory is within the
      // defended territory's bounding box (approximate overlap check)
      const defenderTerritory = await Territory.findById(invasion.territoryId);
      if (!defenderTerritory) continue;

      // Simple proximity check: if any polygon points are within ~200m
      const defCenter = _centroid(defenderTerritory.polygon);
      const atkCenter = _centroid(t.polygon);
      const dist = _haversineDistance(defCenter, atkCenter);

      // If attacker territory center is within 500m of defender territory center,
      // it gets destroyed by the nuke
      if (dist < 500) {
        t.isActive = false;
        await t.save();
        destroyedCount++;
        destroyedArea += t.area;
      }
    }

    // Update attacker's total territory size
    const remainingTerritories = await Territory.find({
      userId: invasion.attackerId,
      isActive: true,
    });
    const newTotalArea = remainingTerritories.reduce((sum, t) => sum + t.area, 0);
    await User.findByIdAndUpdate(invasion.attackerId, {
      territorySize: newTotalArea,
    });

    console.log(`☢️ NUKE USED by ${user.username}: destroyed ${destroyedCount} attacker territories (${destroyedArea.toFixed(0)}m²)`);

    res.json({
      message: 'NUKE DETONATED! Invader\'s territories destroyed!',
      nukesOwned: user.inventory.nukes,
      destroyedCount,
      destroyedArea: Math.round(destroyedArea),
      invasionResolved: true,
    });
  } catch (err) {
    console.error('useNuke error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

// ── Use a Nuke by territory ID (for geometry-based overlaps without a server invasion) ──
// The defender provides their own territoryId + the overlapping enemy's username.
// This creates a resolved invasion on-the-fly so the nuke logic works seamlessly.
exports.useNukeByTerritory = async (req, res) => {
  try {
    const { territoryId, enemyUsername } = req.body;
    if (!territoryId) {
      return res.status(400).json({ error: 'territoryId is required' });
    }

    // Validate territory
    const territory = await Territory.findById(territoryId);
    if (!territory) {
      return res.status(404).json({ error: 'Territory not found' });
    }
    if (territory.userId.toString() !== req.user._id.toString()) {
      return res.status(403).json({ error: 'You can only nuke threats to your own territory' });
    }

    // Check nuke inventory
    const user = await User.findById(req.user._id);
    if (!user || (user.inventory?.nukes || 0) < 1) {
      return res.status(400).json({ error: 'No nukes in inventory' });
    }

    // Find all enemy territories that overlap (within 500m)
    const defCenter = _centroid(territory.polygon);
    const allNearby = await Territory.find({ isActive: true, userId: { $ne: req.user._id } });

    let destroyedCount = 0;
    let destroyedArea = 0;

    for (const t of allNearby) {
      const atkCenter = _centroid(t.polygon);
      const dist = _haversineDistance(defCenter, atkCenter);
      if (dist < 500) {
        t.isActive = false;
        await t.save();
        destroyedCount++;
        destroyedArea += t.area;

        // Update the enemy's total territory size
        const remaining = await Territory.find({ userId: t.userId, isActive: true });
        const newTotal = remaining.reduce((sum, r) => sum + r.area, 0);
        await User.findByIdAndUpdate(t.userId, { territorySize: newTotal });
      }
    }

    // Consume 1 nuke
    user.inventory.nukes -= 1;
    user.markModified('inventory');
    await user.save();

    // Also resolve any active invasions on this territory
    await Invasion.updateMany(
      { territoryId, status: 'active' },
      { $set: { status: 'defended', resolvedAt: new Date() } }
    );

    console.log(`☢️ TERRITORY NUKE by ${user.username}: destroyed ${destroyedCount} enemy territories (${destroyedArea.toFixed(0)}m²)`);

    res.json({
      message: 'NUKE DETONATED! Nearby enemy territories destroyed!',
      nukesOwned: user.inventory.nukes,
      destroyedCount,
      destroyedArea: Math.round(destroyedArea),
    });
  } catch (err) {
    console.error('useNukeByTerritory error:', err);
    res.status(500).json({ error: 'Server error' });
  }
};

// ── Helper: centroid of a polygon ─────────────────────────────────────────────
function _centroid(polygon) {
  if (!polygon || polygon.length === 0) return { lat: 0, lng: 0 };
  const sum = polygon.reduce((acc, p) => ({
    lat: acc.lat + (p.lat || 0),
    lng: acc.lng + (p.lng || 0),
  }), { lat: 0, lng: 0 });
  return { lat: sum.lat / polygon.length, lng: sum.lng / polygon.length };
}

// ── Helper: Haversine distance in meters ──────────────────────────────────────
function _haversineDistance(a, b) {
  const R = 6371000;
  const dLat = (b.lat - a.lat) * Math.PI / 180;
  const dLng = (b.lng - a.lng) * Math.PI / 180;
  const sinLat = Math.sin(dLat / 2);
  const sinLng = Math.sin(dLng / 2);
  const h = sinLat * sinLat +
    Math.cos(a.lat * Math.PI / 180) * Math.cos(b.lat * Math.PI / 180) *
    sinLng * sinLng;
  return 2 * R * Math.asin(Math.sqrt(h));
}
