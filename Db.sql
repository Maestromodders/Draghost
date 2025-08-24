-- Database Schema for WhatsApp Bot Hosting Platform

-- Users table
CREATE TABLE users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL,
    referral_code VARCHAR(20) UNIQUE NOT NULL,
    referrer_id INT,
    verification_token VARCHAR(100),
    is_verified BOOLEAN DEFAULT FALSE,
    is_admin BOOLEAN DEFAULT FALSE,
    coins INT DEFAULT 0 CHECK (coins >= 0),
    last_coin_claim DATE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT valid_username CHECK (username REGEXP '^[a-zA-Z0-9_]+$'),
    CONSTRAINT valid_email CHECK (email REGEXP '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$'),
    FOREIGN KEY (referrer_id) REFERENCES users(id)
);

-- Bots table
CREATE TABLE bots (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    name VARCHAR(100) NOT NULL,
    repo_url VARCHAR(500) NOT NULL,
    env_vars JSON DEFAULT '{}',
    description TEXT,
    heroku_app_id VARCHAR(100),
    heroku_app_name VARCHAR(100),
    status ENUM('pending', 'deploying', 'deployed', 'failed', 'stopped') DEFAULT 'pending',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    last_deployed TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT valid_repo_url CHECK (repo_url REGEXP '^https?://github\\.com/')
);

-- Community messages table
CREATE TABLE community_messages (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    message TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    CONSTRAINT message_length CHECK (LENGTH(message) BETWEEN 1 AND 1000)
);

-- Coin transactions table
CREATE TABLE coin_transactions (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    amount INT NOT NULL,
    type ENUM('daily_claim', 'referral_bonus', 'bot_deployment', 'admin_grant', 'purchase') NOT NULL,
    description TEXT,
    related_bot_id INT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (related_bot_id) REFERENCES bots(id)
);

-- Referral tracking table
CREATE TABLE referrals (
    id INT AUTO_INCREMENT PRIMARY KEY,
    referrer_id INT NOT NULL,
    referred_id INT NOT NULL,
    bonus_given BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(referred_id),
    FOREIGN KEY (referrer_id) REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (referred_id) REFERENCES users(id) ON DELETE CASCADE
);

-- Email verification tokens table
CREATE TABLE email_verification_tokens (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    token VARCHAR(100) NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    used BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- Heroku deployment logs table
CREATE TABLE deployment_logs (
    id INT AUTO_INCREMENT PRIMARY KEY,
    bot_id INT NOT NULL,
    log_type ENUM('deployment', 'build', 'error', 'info') NOT NULL,
    message TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (bot_id) REFERENCES bots(id) ON DELETE CASCADE
);

-- User sessions table
CREATE TABLE user_sessions (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    token VARCHAR(500) NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_activity TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
);

-- Insert admin user (password: admin123)
INSERT INTO users (username, email, password, referral_code, is_verified, is_admin, coins)
VALUES (
    'admin',
    'admin@bothost.com',
    '$2a$12$rD9P2bW6X3L1V7Q8Z9Y0OuKj2N3L4M5Q6R7S8T9U0V1W2X3Y4Z5',
    'ADMIN123',
    TRUE,
    TRUE,
    1000
);

-- Sample data for testing
INSERT INTO users (username, email, password, referral_code, is_verified, coins)
VALUES (
    'testuser',
    'test@example.com',
    '$2a$12$rD9P2bW6X3L1V7Q8Z9Y0OuKj2N3L4M5Q6R7S8T9U0V1W2X3Y4Z5',
    'TEST456',
    TRUE,
    100
);
