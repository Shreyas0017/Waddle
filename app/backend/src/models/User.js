const mongoose = require('mongoose');
const bcrypt = require('bcryptjs');

const userSchema = new mongoose.Schema({
  email: {
    type: String,
    required: true,
    unique: true,
    lowercase: true,
    trim: true,
  },
  username: {
    type: String,
    required: true,
    unique: true,
    trim: true,
  },
  password: {
    type: String,
    required: true,
  },
  totalDistance: {
    type: Number,
    default: 0,
  },
  territorySize: {
    type: Number,
    default: 0,
  },
  activityStreak: {
    type: Number,
    default: 0,
  },
  lastStreakUpdate: {
    type: Date,
    default: null,
  },
  lastActivity: {
    type: Date,
    default: Date.now,
  },
  topazCoins: {
    type: Number,
    default: 0,
  },
  inventory: {
    bombs: { type: Number, default: 0 },
    scannerDocks: { type: Number, default: 0 },
    defuseGuns: { type: Number, default: 0 },
    nukes: { type: Number, default: 0 },
  },
  // Onboarding fields
  dateOfBirth: { type: Date, default: null },
  weight: { type: Number, default: null },
  height: { type: Number, default: null },
  dailyProtein: { type: Number, default: null },
  dailyCalories: { type: Number, default: null },
  avatarPath: { type: String, default: null },
  onboardingCompleted: { type: Boolean, default: false },
  createdAt: {
    type: Date,
    default: Date.now,
  },
});

// Hash password before saving
userSchema.pre('save', async function () {
  if (!this.isModified('password')) return;

  const salt = await bcrypt.genSalt(10);
  this.password = await bcrypt.hash(this.password, salt);
});

// Compare password method
userSchema.methods.comparePassword = async function (candidatePassword) {
  return await bcrypt.compare(candidatePassword, this.password);
};

// Don't return password in JSON
userSchema.methods.toJSON = function () {
  const obj = this.toObject();
  delete obj.password;
  return obj;
};

module.exports = mongoose.model('User', userSchema);
