const express = require('express');
const router = express.Router();
const auth = require('../middleware/auth');
const shop = require('../controllers/shopController');

router.get('/inventory', auth, shop.getInventory);
router.post('/buy-bomb', auth, shop.buyBomb);
router.post('/place-bomb', auth, shop.placeBomb);
router.post('/remove-bomb', auth, shop.removeBomb);
router.post('/apply-bomb-damage', auth, shop.applyBombDamage);
router.post('/buy-scanner-dock', auth, shop.buyScannerDock);
router.post('/buy-defuse-gun', auth, shop.buyDefuseGun);
router.post('/use-scanner-dock', auth, shop.useScannerDock);
router.post('/defuse-bomb', auth, shop.defuseBomb);
router.post('/buy-nuke', auth, shop.buyNuke);
router.post('/use-nuke', auth, shop.useNuke);
router.post('/use-nuke-territory', auth, shop.useNukeByTerritory);

module.exports = router;
