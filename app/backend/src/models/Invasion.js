const mongoose = require('mongoose');

const invasionSchema = new mongoose.Schema({
    // The territory being invaded
    territoryId: {
        type: mongoose.Schema.Types.ObjectId,
        ref: 'Territory',
        required: true,
    },
    // The defender (territory owner)
    defenderId: {
        type: mongoose.Schema.Types.ObjectId,
        ref: 'User',
        required: true,
    },
    defenderUsername: {
        type: String,
        required: true,
    },
    // The attacker (invader)
    attackerId: {
        type: mongoose.Schema.Types.ObjectId,
        ref: 'User',
        required: true,
    },
    attackerUsername: {
        type: String,
        required: true,
    },
    // GPS path the attacker walked inside the territory
    invasionPath: [{
        lat: { type: Number },
        lng: { type: Number },
    }],
    // active = 24h countdown running
    // defended = defender reclaimed in time
    // conquered = 24h expired, attacker wins
    status: {
        type: String,
        enum: ['active', 'defended', 'conquered'],
        default: 'active',
    },
    createdAt: {
        type: Date,
        default: Date.now,
    },
    resolvedAt: {
        type: Date,
        default: null,
    },
});

// Virtual: 24h deadline
invasionSchema.virtual('deadline').get(function () {
    return new Date(this.createdAt.getTime() + 24 * 60 * 60 * 1000);
});

// Virtual: is expired (>24h and still active)
invasionSchema.virtual('isExpired').get(function () {
    return this.status === 'active' && Date.now() > this.deadline.getTime();
});

// Include virtuals in JSON
invasionSchema.set('toJSON', { virtuals: true });
invasionSchema.set('toObject', { virtuals: true });

module.exports = mongoose.model('Invasion', invasionSchema);
