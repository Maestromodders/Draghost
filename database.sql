-- Database Schema for WhatsApp Bot Hosting Platform

-- Enable UUID extension for better primary keys
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Users table
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL,
    referral_code VARCHAR(20) UNIQUE NOT NULL,
    referrer_id UUID REFERENCES users(id),
    verification_token VARCHAR(100),
    is_verified BOOLEAN DEFAULT FALSE,
    is_admin BOOLEAN DEFAULT FALSE,
    coins INTEGER DEFAULT 0 CHECK (coins >= 0),
    last_coin_claim DATE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_username CHECK (username ~ '^[a-zA-Z0-9_]+$'),
    CONSTRAINT valid_email CHECK (email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
);

-- Bots table
CREATE TABLE bots (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    repo_url VARCHAR(500) NOT NULL,
    env_vars JSONB DEFAULT '{}',
    description TEXT,
    heroku_app_id VARCHAR(100),
    heroku_app_name VARCHAR(100),
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'deploying', 'deployed', 'failed', 'stopped')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_deployed TIMESTAMP,
    CONSTRAINT valid_repo_url CHECK (repo_url ~ '^https?://github\.com/')
);

-- Community messages table
CREATE TABLE community_messages (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    message TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT message_length CHECK (LENGTH(message) BETWEEN 1 AND 1000)
);

-- Coin transactions table
CREATE TABLE coin_transactions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    amount INTEGER NOT NULL,
    type VARCHAR(20) NOT NULL CHECK (type IN ('daily_claim', 'referral_bonus', 'bot_deployment', 'admin_grant', 'purchase')),
    description TEXT,
    related_bot_id UUID REFERENCES bots(id),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Referral tracking table
CREATE TABLE referrals (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    referrer_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    referred_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    bonus_given BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(referred_id) -- Prevent multiple referrals for same user
);

-- Email verification tokens table
CREATE TABLE email_verification_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token VARCHAR(100) NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    used BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Heroku deployment logs table
CREATE TABLE deployment_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bot_id UUID NOT NULL REFERENCES bots(id) ON DELETE CASCADE,
    log_type VARCHAR(20) NOT NULL CHECK (log_type IN ('deployment', 'build', 'error', 'info')),
    message TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- User sessions table
CREATE TABLE user_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token VARCHAR(500) NOT NULL,
    expires_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_activity TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes for better performance
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_username ON users(username);
CREATE INDEX idx_users_referral_code ON users(referral_code);
CREATE INDEX idx_bots_user_id ON bots(user_id);
CREATE INDEX idx_bots_status ON bots(status);
CREATE INDEX idx_community_messages_user_id ON community_messages(user_id);
CREATE INDEX idx_community_messages_created_at ON community_messages(created_at);
CREATE INDEX idx_coin_transactions_user_id ON coin_transactions(user_id);
CREATE INDEX idx_referrals_referrer_id ON referrals(referrer_id);
CREATE INDEX idx_email_verification_tokens_token ON email_verification_tokens(token);
CREATE INDEX idx_deployment_logs_bot_id ON deployment_logs(bot_id);

-- Triggers for updated_at timestamps
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_bots_updated_at BEFORE UPDATE ON bots
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Function to handle referral bonuses
CREATE OR REPLACE FUNCTION handle_referral_bonus()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.referrer_id IS NOT NULL THEN
        -- Give bonus to referrer
        UPDATE users SET coins = coins + 100 WHERE id = NEW.referrer_id;
        
        -- Record referral
        INSERT INTO referrals (referrer_id, referred_id, bonus_given)
        VALUES (NEW.referrer_id, NEW.id, TRUE);
        
        -- Record transaction for referrer
        INSERT INTO coin_transactions (user_id, amount, type, description)
        VALUES (NEW.referrer_id, 100, 'referral_bonus', 'Referral bonus for new user: ' || NEW.username);
        
        -- Give initial coins to new user from referral
        UPDATE users SET coins = coins + 50 WHERE id = NEW.id;
        
        -- Record transaction for new user
        INSERT INTO coin_transactions (user_id, amount, type, description)
        VALUES (NEW.id, 50, 'referral_bonus', 'Welcome bonus from referral');
    END IF;
    
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER after_user_insert AFTER INSERT ON users
    FOR EACH ROW EXECUTE FUNCTION handle_referral_bonus();

-- Function to handle daily coin claims
CREATE OR REPLACE FUNCTION handle_daily_coin_claim()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.last_coin_claim IS NOT NULL AND OLD.last_coin_claim IS DISTINCT FROM NEW.last_coin_claim THEN
        INSERT INTO coin_transactions (user_id, amount, type, description)
        VALUES (NEW.id, 10, 'daily_claim', 'Daily coin claim');
    END IF;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER after_coin_claim AFTER UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION handle_daily_coin_claim();

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

-- Comments for documentation
COMMENT ON TABLE users IS 'Stores user accounts and their coin balances';
COMMENT ON TABLE bots IS 'Stores WhatsApp bot deployments and their status';
COMMENT ON TABLE community_messages IS 'Stores community chat messages';
COMMENT ON TABLE coin_transactions IS 'Tracks all coin transactions for audit purposes';
COMMENT ON TABLE referrals IS 'Tracks referral relationships and bonuses';
COMMENT ON TABLE email_verification_tokens IS 'Stores email verification tokens with expiration';
COMMENT ON TABLE deployment_logs IS 'Logs Heroku deployment activities';
COMMENT ON TABLE user_sessions IS 'Manages user authentication sessions';
