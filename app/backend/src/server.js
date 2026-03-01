const express = require('express');
const mongoose = require('mongoose');
const cors = require('cors');
require('dotenv').config();

const authRoutes = require('./routes/auth');
const userRoutes = require('./routes/users');
const territoryRoutes = require('./routes/territories');
const sessionRoutes = require('./routes/sessions');
const leaderboardRoutes = require('./routes/leaderboard');
const mapsRoutes = require('./routes/maps');
const eventRoutes = require('./routes/events');
const shopRoutes = require('./routes/shop');
const invasionRoutes = require('./routes/invasions');
const { startInactivityChecker } = require('./utils/inactivityChecker');

const app = express();

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Request logging
app.use((req, res, next) => {
  console.log(`📥 ${new Date().toISOString()} ${req.method} ${req.url}`);
  if (req.method === 'POST' || req.method === 'PUT') {
    console.log('📦 Body keys:', Object.keys(req.body || {}));
  }
  next();
});

// Routes
app.use('/api/v1/auth', authRoutes);
app.use('/api/v1/users', userRoutes);
app.use('/api/v1/territories', territoryRoutes);
app.use('/api/v1/sessions', sessionRoutes);
app.use('/api/v1/leaderboard', leaderboardRoutes);
app.use('/api/v1/maps', mapsRoutes);
app.use('/api/v1/events', eventRoutes);
app.use('/api/v1/shop', shopRoutes);
app.use('/api/v1/invasions', invasionRoutes);

// Health check
app.get('/health', (req, res) => {
  res.json({ status: 'OK', message: 'Kingdom Runner API is running' });
});

// Ping endpoint for keeping server alive (useful for Render/Heroku free tier)
app.get('/ping', (req, res) => {
  const uptime = process.uptime();
  res.json({
    status: 'alive',
    message: 'Pong! Server is active',
    timestamp: new Date().toISOString(),
    uptime: `${Math.floor(uptime / 60)} minutes ${Math.floor(uptime % 60)} seconds`
  });
});

// MongoDB Connection
const MONGODB_URI = process.env.MONGODB_URI;

if (!MONGODB_URI) {
  console.error('❌ MONGODB_URI is not defined in environment variables');
  process.exit(1);
}

mongoose.connect(MONGODB_URI)
  .then(() => {
    console.log('✅ Connected to MongoDB');
    // Start the inactivity checker after successful DB connection
    startInactivityChecker();
  })
  .catch((error) => {
    console.error('❌ MongoDB connection error:', error);
    process.exit(1);
  });

// Error handling middleware
app.use((err, req, res, next) => {
  console.error(err.stack);
  res.status(500).json({ error: 'Something went wrong!' });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Route not found' });
});

const PORT = process.env.PORT || 3000;

app.listen(PORT, () => {
  console.log(`🚀 Server is running on port ${PORT}`);
  console.log(`📍 Health check: http://localhost:${PORT}/health`);
});

module.exports = app;
