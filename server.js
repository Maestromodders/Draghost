require('dotenv').config();
const express = require('express');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const nodemailer = require('nodemailer');
const { Pool } = require('pg');
const axios = require('axios');

const app = express();
const PORT = process.env.PORT || 3000;

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.static('public'));

// Database connection
const pool = new Pool({
    connectionString: process.env.DATABASE_URL,
    ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

// Email transporter
const transporter = nodemailer.createTransporter({
    service: 'gmail',
    auth: {
        user: process.env.EMAIL_USER,
        pass: process.env.EMAIL_PASS
    }
});

// Helper functions
const generateVerificationToken = () => Math.random().toString(36).substring(2) + Date.now().toString(36);

// Authentication middleware
const authenticateToken = (req, res, next) => {
    const authHeader = req.headers['authorization'];
    const token = authHeader && authHeader.split(' ')[1];

    if (!token) return res.status(401).json({ error: 'Access token required' });

    jwt.verify(token, process.env.JWT_SECRET, (err, user) => {
        if (err) return res.status(403).json({ error: 'Invalid token' });
        req.user = user;
        next();
    });
};

// Routes

// Check username availability
app.get('/api/check-username/:username', async (req, res) => {
    try {
        const { username } = req.params;
        const result = await pool.query('SELECT id FROM users WHERE username = $1', [username]);
        res.json({ available: result.rows.length === 0 });
    } catch (error) {
        res.status(500).json({ error: 'Server error' });
    }
});

// Check email availability
app.get('/api/check-email/:email', async (req, res) => {
    try {
        const { email } = req.params;
        const result = await pool.query('SELECT id FROM users WHERE email = $1', [email]);
        res.json({ available: result.rows.length === 0 });
    } catch (error) {
        res.status(500).json({ error: 'Server error' });
    }
});

// Register user
app.post('/api/register', async (req, res) => {
    try {
        const { username, email, password, referralCode } = req.body;

        // Check if user exists
        const userExists = await pool.query('SELECT id FROM users WHERE email = $1 OR username = $2', [email, username]);
        if (userExists.rows.length > 0) {
            return res.status(400).json({ error: 'User already exists' });
        }

        // Hash password
        const hashedPassword = await bcrypt.hash(password, 12);

        // Handle referral
        let referrerId = null;
        if (referralCode) {
            const referrerResult = await pool.query('SELECT id FROM users WHERE referral_code = $1', [referralCode]);
            if (referrerResult.rows.length > 0) {
                referrerId = referrerResult.rows[0].id;
            }
        }

        // Generate referral code
        const referralCodeNew = username + Math.random().toString(36).substring(2, 8).toUpperCase();

        // Create user
        const verificationToken = generateVerificationToken();
        const result = await pool.query(
            `INSERT INTO users (username, email, password, referral_code, referrer_id, verification_token, coins) 
             VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id, username, email, coins`,
            [username, email, hashedPassword, referralCodeNew, referrerId, verificationToken, referrerId ? 50 : 0]
        );

        // Give bonus to referrer
        if (referrerId) {
            await pool.query('UPDATE users SET coins = coins + 100 WHERE id = $1', [referrerId]);
        }

        // Send verification email
        const verificationLink = `${process.env.BASE_URL}/verify-email?token=${verificationToken}`;
        await transporter.sendMail({
            from: process.env.EMAIL_USER,
            to: email,
            subject: 'Verify your email - BotHost',
            html: `Please click <a href="${verificationLink}">here</a> to verify your email address.`
        });

        // Generate JWT
        const token = jwt.sign(
            { userId: result.rows[0].id, email: result.rows[0].email },
            process.env.JWT_SECRET,
            { expiresIn: '7d' }
        );

        res.json({
            token,
            user: {
                id: result.rows[0].id,
                username: result.rows[0].username,
                email: result.rows[0].email,
                coins: result.rows[0].coins
            }
        });
    } catch (error) {
        console.error(error);
        res.status(500).json({ error: 'Registration failed' });
    }
});

// Login user
app.post('/api/login', async (req, res) => {
    try {
        const { email, password } = req.body;

        const result = await pool.query('SELECT * FROM users WHERE email = $1', [email]);
        if (result.rows.length === 0) {
            return res.status(400).json({ error: 'Invalid credentials' });
        }

        const user = result.rows[0];

        // Check if email is verified
        if (!user.is_verified) {
            return res.status(400).json({ error: 'Please verify your email first' });
        }

        const validPassword = await bcrypt.compare(password, user.password);
        if (!validPassword) {
            return res.status(400).json({ error: 'Invalid credentials' });
        }

        const token = jwt.sign(
            { userId: user.id, email: user.email },
            process.env.JWT_SECRET,
            { expiresIn: '7d' }
        );

        res.json({
            token,
            user: {
                id: user.id,
                username: user.username,
                email: user.email,
                coins: user.coins,
                isAdmin: user.is_admin
            }
        });
    } catch (error) {
        res.status(500).json({ error: 'Login failed' });
    }
});

// Verify email
app.get('/api/verify-email', async (req, res) => {
    try {
        const { token } = req.query;
        const result = await pool.query('UPDATE users SET is_verified = true WHERE verification_token = $1 RETURNING *', [token]);

        if (result.rows.length === 0) {
            return res.status(400).json({ error: 'Invalid verification token' });
        }

        res.json({ message: 'Email verified successfully' });
    } catch (error) {
        res.status(500).json({ error: 'Verification failed' });
    }
});

// Claim daily coins
app.post('/api/claim-daily-coins', authenticateToken, async (req, res) => {
    try {
        const userId = req.user.userId;
        const today = new Date().toISOString().split('T')[0];

        // Check if already claimed today
        const lastClaim = await pool.query(
            'SELECT last_coin_claim FROM users WHERE id = $1',
            [userId]
        );

        if (lastClaim.rows[0].last_coin_claim === today) {
            return res.status(400).json({ error: 'Already claimed coins today' });
        }

        // Add coins and update last claim date
        await pool.query(
            'UPDATE users SET coins = coins + 10, last_coin_claim = $1 WHERE id = $2',
            [today, userId]
        );

        const newBalance = await pool.query('SELECT coins FROM users WHERE id = $1', [userId]);

        res.json({ coins: newBalance.rows[0].coins, message: '10 coins claimed successfully' });
    } catch (error) {
        res.status(500).json({ error: 'Failed to claim coins' });
    }
});

// Get user profile
app.get('/api/profile', authenticateToken, async (req, res) => {
    try {
        const userId = req.user.userId;
        const result = await pool.query(
            'SELECT id, username, email, coins, referral_code, created_at FROM users WHERE id = $1',
            [userId]
        );

        res.json(result.rows[0]);
    } catch (error) {
        res.status(500).json({ error: 'Failed to fetch profile' });
    }
});

// Get user bots
app.get('/api/bots', authenticateToken, async (req, res) => {
    try {
        const userId = req.user.userId;
        const result = await pool.query(
            'SELECT * FROM bots WHERE user_id = $1 ORDER BY created_at DESC',
            [userId]
        );

        res.json(result.rows);
    } catch (error) {
        res.status(500).json({ error: 'Failed to fetch bots' });
    }
});

// Deploy new bot
app.post('/api/bots', authenticateToken, async (req, res) => {
    try {
        const userId = req.user.userId;
        const { botName, repoUrl, envVars, description } = req.body;

        // Check coin balance
        const userResult = await pool.query('SELECT coins FROM users WHERE id = $1', [userId]);
        if (userResult.rows[0].coins < 50) {
            return res.status(400).json({ error: 'Insufficient coins' });
        }

        // Deduct coins
        await pool.query('UPDATE users SET coins = coins - 50 WHERE id = $1', [userId]);

        // Create bot record
        const botResult = await pool.query(
            `INSERT INTO bots (user_id, name, repo_url, env_vars, description, status) 
             VALUES ($1, $2, $3, $4, $5, 'pending') RETURNING *`,
            [userId, botName, repoUrl, envVars, description]
        );

        // In a real implementation, this would call Heroku API
        // For now, we'll simulate deployment
        setTimeout(async () => {
            await pool.query('UPDATE bots SET status = $1 WHERE id = $2', ['deployed', botResult.rows[0].id]);
        }, 5000);

        res.json({ message: 'Bot deployment started', bot: botResult.rows[0] });
    } catch (error) {
        res.status(500).json({ error: 'Failed to deploy bot' });
    }
});

// Get community messages
app.get('/api/community/messages', authenticateToken, async (req, res) => {
    try {
        const result = await pool.query(`
            SELECT m.*, u.username 
            FROM community_messages m 
            JOIN users u ON m.user_id = u.id 
            ORDER BY m.created_at DESC 
            LIMIT 50
        `);

        res.json(result.rows);
    } catch (error) {
        res.status(500).json({ error: 'Failed to fetch messages' });
    }
});

// Send community message
app.post('/api/community/messages', authenticateToken, async (req, res) => {
    try {
        const userId = req.user.userId;
        const { message } = req.body;

        const result = await pool.query(
            'INSERT INTO community_messages (user_id, message) VALUES ($1, $2) RETURNING *',
            [userId, message]
        );

        // Get message with username
        const messageWithUser = await pool.query(`
            SELECT m.*, u.username 
            FROM community_messages m 
            JOIN users u ON m.user_id = u.id 
            WHERE m.id = $1
        `, [result.rows[0].id]);

        res.json(messageWithUser.rows[0]);
    } catch (error) {
        res.status(500).json({ error: 'Failed to send message' });
    }
});

// Admin routes
app.get('/api/admin/bots', authenticateToken, async (req, res) => {
    try {
        // Check if user is admin
        const userResult = await pool.query('SELECT is_admin FROM users WHERE id = $1', [req.user.userId]);
        if (!userResult.rows[0].is_admin) {
            return res.status(403).json({ error: 'Admin access required' });
        }

        const result = await pool.query(`
            SELECT b.*, u.username, u.email 
            FROM bots b 
            JOIN users u ON b.user_id = u.id 
            ORDER BY b.created_at DESC
        `);

        res.json(result.rows);
    } catch (error) {
        res.status(500).json({ error: 'Failed to fetch bots' });
    }
});

// Update bot environment variables (admin)
app.put('/api/admin/bots/:id/env', authenticateToken, async (req, res) => {
    try {
        // Check if user is admin
        const userResult = await pool.query('SELECT is_admin FROM users WHERE id = $1', [req.user.userId]);
        if (!userResult.rows[0].is_admin) {
            return res.status(403).json({ error: 'Admin access required' });
        }

        const { id } = req.params;
        const { envVars } = req.body;

        await pool.query('UPDATE bots SET env_vars = $1 WHERE id = $2', [envVars, id]);

        res.json({ message: 'Environment variables updated' });
    } catch (error) {
        res.status(500).json({ error: 'Failed to update environment variables' });
    }
});

// Get system statistics (admin)
app.get('/api/admin/stats', authenticateToken, async (req, res) => {
    try {
        // Check if user is admin
        const userResult = await pool.query('SELECT is_admin FROM users WHERE id = $1', [req.user.userId]);
        if (!userResult.rows[0].is_admin) {
            return res.status(403).json({ error: 'Admin access required' });
        }

        const [
            totalUsers,
            totalBots,
            activeBots,
            totalCoins
        ] = await Promise.all([
            pool.query('SELECT COUNT(*) FROM users'),
            pool.query('SELECT COUNT(*) FROM bots'),
            pool.query('SELECT COUNT(*) FROM bots WHERE status = $1', ['deployed']),
            pool.query('SELECT SUM(coins) FROM users')
        ]);

        res.json({
            totalUsers: parseInt(totalUsers.rows[0].count),
            totalBots: parseInt(totalBots.rows[0].count),
            activeBots: parseInt(activeBots.rows[0].count),
            totalCoins: parseInt(totalCoins.rows[0].sum || 0)
        });
    } catch (error) {
        res.status(500).json({ error: 'Failed to fetch statistics' });
    }
});

// Serve frontend
app.get('*', (req, res) => {
    res.sendFile('index.html', { root: './public' });
});

app.listen(PORT, () => {
    console.log(`Server running on port ${PORT}`);
});

