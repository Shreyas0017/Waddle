const Invasion = require('../models/Invasion');
const Territory = require('../models/Territory');
const User = require('../models/User');

// ── Report an invasion ────────────────────────────────────────────────────────
// Called by the attacker's device when invasion threshold is reached.
exports.reportInvasion = async (req, res) => {
    try {
        const { territoryId, invasionPath } = req.body;
        if (!territoryId) {
            return res.status(400).json({ error: 'territoryId is required' });
        }

        const territory = await Territory.findById(territoryId);
        if (!territory) {
            return res.status(404).json({ error: 'Territory not found' });
        }

        // Can't invade your own territory
        if (territory.userId.toString() === req.user._id.toString()) {
            return res.status(400).json({ error: 'Cannot invade your own territory' });
        }

        // Check for existing active invasion by same attacker on same territory
        const existing = await Invasion.findOne({
            territoryId,
            attackerId: req.user._id,
            status: 'active',
        });

        if (existing) {
            // Update the invasion path if provided
            if (invasionPath && invasionPath.length > 0) {
                existing.invasionPath = invasionPath;
                await existing.save();
            }
            return res.json({ invasion: existing, message: 'Invasion already active' });
        }

        // Look up defender info
        const defender = await User.findById(territory.userId);

        const invasion = new Invasion({
            territoryId,
            defenderId: territory.userId,
            defenderUsername: defender ? defender.username : territory.username,
            attackerId: req.user._id,
            attackerUsername: req.user.username,
            invasionPath: invasionPath || [],
        });

        await invasion.save();
        console.log(`⚔️ Invasion reported: ${req.user.username} → ${invasion.defenderUsername}'s territory`);

        res.status(201).json({ invasion, message: 'Invasion reported' });
    } catch (err) {
        console.error('reportInvasion error:', err);
        res.status(500).json({ error: 'Server error' });
    }
};

// ── Get my invasions (as attacker or defender) ────────────────────────────────
exports.getMyInvasions = async (req, res) => {
    try {
        const userId = req.user._id;

        // Auto-resolve expired invasions first
        const now = new Date();
        const cutoff = new Date(now.getTime() - 24 * 60 * 60 * 1000);

        await Invasion.updateMany(
            { status: 'active', createdAt: { $lt: cutoff } },
            { $set: { status: 'conquered', resolvedAt: now } }
        );

        // Fetch all invasions involving this user (active + recent resolved)
        // Only show resolved ones from last 7 days
        const sevenDaysAgo = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);

        const invasions = await Invasion.find({
            $or: [
                { attackerId: userId },
                { defenderId: userId },
            ],
            $or: [
                { status: 'active' },
                { resolvedAt: { $gte: sevenDaysAgo } },
            ],
        }).sort({ createdAt: -1 }).limit(20);

        // Annotate each invasion with the user's role
        const annotated = invasions.map(inv => {
            const obj = inv.toJSON();
            obj.role = inv.attackerId.toString() === userId.toString() ? 'attacker' : 'defender';

            // Calculate time remaining for active invasions
            if (inv.status === 'active') {
                const deadline = new Date(inv.createdAt.getTime() + 24 * 60 * 60 * 1000);
                const remaining = deadline.getTime() - now.getTime();
                obj.timeRemainingMs = Math.max(0, remaining);
                obj.deadline = deadline.toISOString();
            }

            return obj;
        });

        res.json({ invasions: annotated });
    } catch (err) {
        console.error('getMyInvasions error:', err);
        res.status(500).json({ error: 'Server error' });
    }
};

// ── Defend (reclaim) an invasion ──────────────────────────────────────────────
exports.defendInvasion = async (req, res) => {
    try {
        const { id } = req.params;

        const invasion = await Invasion.findById(id);
        if (!invasion) {
            return res.status(404).json({ error: 'Invasion not found' });
        }

        // Only the defender can defend
        if (invasion.defenderId.toString() !== req.user._id.toString()) {
            return res.status(403).json({ error: 'Only the territory owner can defend' });
        }

        if (invasion.status !== 'active') {
            return res.status(400).json({ error: `Invasion already ${invasion.status}` });
        }

        // Check if expired (>24h)
        const deadline = new Date(invasion.createdAt.getTime() + 24 * 60 * 60 * 1000);
        if (Date.now() > deadline.getTime()) {
            invasion.status = 'conquered';
            invasion.resolvedAt = new Date();
            await invasion.save();
            return res.status(400).json({ error: 'Too late! The 24h window has expired.', invasion });
        }

        invasion.status = 'defended';
        invasion.resolvedAt = new Date();
        await invasion.save();

        console.log(`🛡️ Territory defended by ${req.user.username}`);

        res.json({ invasion, message: 'Territory successfully defended!' });
    } catch (err) {
        console.error('defendInvasion error:', err);
        res.status(500).json({ error: 'Server error' });
    }
};
