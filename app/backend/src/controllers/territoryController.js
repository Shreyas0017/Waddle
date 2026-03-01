const Territory = require('../models/Territory');
const User = require('../models/User');
const { calculatePolygonArea, calculateDistance, sanitizePath } = require('../utils/geometry');

// Get all territories
exports.getTerritories = async (req, res) => {
  try {
    const territories = await Territory.find({ isActive: true }).sort({ createdAt: -1 });
    console.log(`🗺️ Fetching all territories: ${territories.length} found`);
    territories.forEach(t => {
      console.log(`  - Territory ${t._id}: ${t.username}, ${t.area.toFixed(2)} m², ${t.polygon.length} points`);
    });
    res.json(territories);
  } catch (error) {
    console.error('Get territories error:', error);
    res.status(500).json({ error: 'Server error' });
  }
};

// Create new territory
exports.createTerritory = async (req, res) => {
  try {
    console.log('🌍 CREATE TERRITORY REQUEST');
    
    const { path, formsClosedLoop } = req.body;
    console.log(`📦 User: ${req.user.username}, Raw points: ${path ? path.length : 0}`);

    if (!path || path.length < 1) {
      console.log('❌ REJECTED: No points provided');
      return res.status(400).json({ error: 'No path provided' });
    }

    // ── Step 1: Sanitize path — remove GPS outlier points ──────────────────
    const cleanPath = sanitizePath(path);
    console.log(`🧹 Sanitized: ${path.length} → ${cleanPath.length} points`);

    if (cleanPath.length < 3) {
      console.log('❌ REJECTED: Not enough clean GPS points for territory');
      return res.status(400).json({ 
        error: 'Not enough valid GPS points after filtering (need ≥3)' 
      });
    }

    // ── Step 2: Calculate walked distance and validate ─────────────────────
    const walkDistance = calculateDistance(cleanPath);
    console.log(`📏 Walk distance: ${walkDistance.toFixed(1)}m`);

    if (walkDistance < 20) {
      console.log(`❌ REJECTED: Walk too short (${walkDistance.toFixed(1)}m)`);
      return res.status(400).json({ 
        error: `Walk too short (${walkDistance.toFixed(0)}m). Need at least 20m.` 
      });
    }

    // ── Step 3: Calculate area and validate plausibility ───────────────────
    const area = calculatePolygonArea(cleanPath);
    // Max reasonable area: walkDistance × 25m (generous strip width)
    // A perfect circle of perimeter L encloses L²/(4π) ≈ L²/12.6
    // Using L×25 is ~3x more generous than physics allows
    const maxArea = Math.max(walkDistance * 25, 500);
    console.log(`📐 Area: ${area.toFixed(0)}m², Max allowed: ${maxArea.toFixed(0)}m²`);

    if (area > maxArea) {
      console.log(`❌ REJECTED: Area ${area.toFixed(0)}m² > max ${maxArea.toFixed(0)}m² for ${walkDistance.toFixed(0)}m walk`);
      return res.status(400).json({ 
        error: `Territory too large (${area.toFixed(0)}m²) for walk distance (${walkDistance.toFixed(0)}m)` 
      });
    }

    // ── Step 4: Create territory ──────────────────────────────────────────
    console.log(`✅ Area accepted: ${area.toFixed(2)} m²`);

    const territory = new Territory({
      userId: req.user._id,
      username: req.user.username,
      polygon: cleanPath,
      area,
    });

    await territory.save();
    console.log(`✅ Territory created: ${territory._id}, ${area.toFixed(0)}m²`);

    // Update user's total territory size
    const userTerritories = await Territory.find({ 
      userId: req.user._id, 
      isActive: true 
    });
    const totalArea = userTerritories.reduce((sum, t) => sum + t.area, 0);

    // ── Topaz coin reward ─────────────────────────────────────────────────
    // Base: 1 Topaz per 100m² (min 5, max 200)
    // Streak bonus: >7 days → ×2.0, >3 days → ×1.5
    const baseCoins = Math.floor(area / 100);
    const streak = req.user.activityStreak || 0;
    const multiplier = streak > 7 ? 2.0 : streak > 3 ? 1.5 : 1.0;
    const topazEarned = Math.min(Math.max(Math.round(baseCoins * multiplier), 5), 200);

    const updatedUser = await User.findByIdAndUpdate(req.user._id, {
      territorySize: totalArea,
      lastActivity: new Date(),
      $inc: { topazCoins: topazEarned },
    }, { new: true });

    const totalTopaz = updatedUser ? updatedUser.topazCoins : topazEarned;
    console.log(`💎 Topaz awarded: +${topazEarned} (streak ×${multiplier}) → total ${totalTopaz}`);
    
    console.log(`📊 User ${req.user.username} total territory: ${totalArea.toFixed(0)}m²`);

    res.status(201).json({ territory, topazEarned, totalTopaz });
  } catch (error) {
    console.error('Create territory error:', error);
    res.status(500).json({ error: 'Server error creating territory', details: error.message });
  }
};

// Merge nearby territories
exports.mergeTerritories = async (req, res) => {
  try {
    console.log('🤝 MERGE TERRITORIES REQUEST RECEIVED');
    const { territoryIds, mergedPath, mergedArea } = req.body;

    console.log(`Merging territories: ${territoryIds.join(', ')}`);
    console.log(`Merged path points: ${mergedPath.length}, Area: ${mergedArea} m²`);

    // Verify both territories belong to the user
    const territories = await Territory.find({
      _id: { $in: territoryIds },
      userId: req.user._id,
      isActive: true
    });

    if (territories.length !== territoryIds.length) {
      return res.status(400).json({ error: 'Invalid territories or not owned by user' });
    }

    // Deactivate old territories
    await Territory.updateMany(
      { _id: { $in: territoryIds } },
      { isActive: false }
    );

    // Create merged territory
    const mergedTerritory = new Territory({
      userId: req.user._id,
      username: req.user.username,
      polygon: mergedPath,
      area: mergedArea,
    });

    await mergedTerritory.save();
    console.log(`✅ Merged territory created: ${mergedTerritory._id}`);

    // Update user's total territory size
    const userTerritories = await Territory.find({ 
      userId: req.user._id, 
      isActive: true 
    });
    const totalArea = userTerritories.reduce((sum, t) => sum + t.area, 0);
    
    await User.findByIdAndUpdate(req.user._id, {
      territorySize: totalArea,
      lastActivity: new Date(),
    });
    
    console.log(`✅ User territory updated after merge: ${totalArea.toFixed(2)} m²`);

    res.status(201).json(mergedTerritory);
  } catch (error) {
    console.error('Merge territories error:', error);
    res.status(500).json({ error: 'Server error merging territories', details: error.message });
  }
};

// Get user territories
exports.getUserTerritories = async (req, res) => {
  try {
    const territories = await Territory.find({ 
      userId: req.params.userId,
      isActive: true 
    });
    res.json(territories);
  } catch (error) {
    console.error('Get user territories error:', error);
    res.status(500).json({ error: 'Server error' });
  }
};
