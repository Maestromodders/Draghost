const { Pool } = require('pg');
const fs = require('fs');
const path = require('path');

require('dotenv').config();

async function runMigrations() {
    const pool = new Pool({
        connectionString: process.env.DATABASE_URL,
        ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
    });

    try {
        console.log('Running database migrations...');
        
        // Read schema file
        const schemaPath = path.join(__dirname, '../database_schema.sql');
        const schemaSql = fs.readFileSync(schemaPath, 'utf8');
        
        // Split into individual statements
        const statements = schemaSql.split(';').filter(stmt => stmt.trim());
        
        for (let i = 0; i < statements.length; i++) {
            const statement = statements[i] + ';';
            console.log(`Executing statement ${i + 1}/${statements.length}`);
            
            try {
                await pool.query(statement);
            } catch (error) {
                console.warn(`Warning executing statement ${i + 1}:`, error.message);
                // Continue with next statement for some errors like duplicate indexes
                if (!error.message.includes('already exists')) {
                    throw error;
                }
            }
        }
        
        console.log('Database migrations completed successfully!');
    } catch (error) {
        console.error('Migration failed:', error);
        process.exit(1);
    } finally {
        await pool.end();
    }
}

runMigrations();
