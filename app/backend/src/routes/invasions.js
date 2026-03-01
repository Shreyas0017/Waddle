const express = require('express');
const router = express.Router();
const invasionController = require('../controllers/invasionController');
const auth = require('../middleware/auth');

// Report an invasion (called by attacker)
router.post('/report', auth, invasionController.reportInvasion);

// Get all invasions involving current user
router.get('/mine', auth, invasionController.getMyInvasions);

// Defend (reclaim) a specific invasion
router.post('/:id/defend', auth, invasionController.defendInvasion);

module.exports = router;
