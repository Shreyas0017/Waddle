const mongoose = require('mongoose');

const territorySchema = new mongoose.Schema({
  userId: {
    type: mongoose.Schema.Types.ObjectId,
    ref: 'User',
    required: true,
  },
  username: {
    type: String,
    required: true,
  },
  polygon: [{
    lat: {
      type: Number,
      required: true,
    },
    lng: {
      type: Number,
      required: true,
    },
  }],
  area: {
    type: Number,
    required: true,
  },
  isActive: {
    type: Boolean,
    default: true,
  },
  bombCount: {
    type: Number,
    default: 0,
    min: 0,
    max: 3,
  },
  bombPositions: [
    {
      lat: { type: Number, required: true },
      lng: { type: Number, required: true },
    },
  ],
  createdAt: {
    type: Date,
    default: Date.now,
  },
  lastUpdated: {
    type: Date,
    default: Date.now,
  },
});

// Update lastUpdated before saving
territorySchema.pre('save', function() {
  this.lastUpdated = Date.now();
});

module.exports = mongoose.model('Territory', territorySchema);
