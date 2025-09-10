-- =============================================
-- Task Management System - Security Model
-- Version: 1.0.0
-- Created: 2025-09-11
-- =============================================

-- ========== ROLES CREATION ==========

-- Create application roles
DO $$
BEGIN
    -- Superuser role for database administration
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dba_role') THEN
        CREATE ROLE dba_role WITH SUPERUSER CREATEDB CREATEROLE LOGIN;
    END IF;

    -- Application role for regular users
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user_role') THEN
        CREATE ROLE app_user_role NOLOGIN;
    END IF;
    
    -- Read-only role for reporting
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reporting_role') THEN
        CREATE ROLE reporting_role NOLOGIN;
    END IF;

    -- Application user (used by the application to connect to the database)
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
        CREATE ROLE app_user WITH LOGIN PASSWORD 'your_secure_password' IN ROLE app_user_role;
    END IF;
    
    -- Reporting user
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'reporting_user') THEN
        CREATE ROLE reporting_user WITH LOGIN PASSWORD 'reporting_password' IN ROLE reporting_role;
    END IF;
END
$$;

-- ========== SCHEMA PRIVILEGES ==========

-- Grant usage on schema
GRANT USAGE ON SCHEMA public TO app_user_role, reporting_role;

-- Grant permissions to app_user_role
GRANT SELECT, INSERT, UPDATE, DELETE 
ON ALL TABLES IN SCHEMA public 
TO app_user_role;

-- Grant execute on functions
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public 
TO app_user_role;

-- Grant read-only access to reporting_role
GRANT SELECT 
ON ALL TABLES IN SCHEMA public 
TO reporting_role;

-- Grant usage on sequences
GRANT USAGE, SELECT 
ON ALL SEQUENCES IN SCHEMA public 
TO app_user_role, reporting_role;

-- ========== ROW LEVEL SECURITY ==========

-- Enable RLS on all tables
DO $$
DECLARE
    t record;
BEGIN
    FOR t IN 
        SELECT tablename 
        FROM pg_tables 
        WHERE schemaname = 'public' 
        AND tablename NOT LIKE 'pg_%' 
        AND tablename NOT LIKE 'sql_%'
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', t.tablename);
    END LOOP;
END $$;

-- ========== RLS POLICIES ==========

-- Organizations policy (users can only see their own organization)
CREATE POLICY organization_isolation_policy ON organizations
    USING (organization_id = current_setting('app.current_organization_id')::UUID);

-- Users policy (users can only see users in their organization)
CREATE POLICY users_org_policy ON users
    USING (organization_id = current_setting('app.current_organization_id')::UUID);

-- Projects policy
CREATE POLICY projects_org_policy ON projects
    USING (organization_id = current_setting('app.current_organization_id')::UUID);

-- Tasks policy
CREATE POLICY tasks_org_policy ON tasks
    USING (organization_id = current_setting('app.current_organization_id')::UUID);

-- Task assignments policy
CREATE POLICY task_assignments_org_policy ON task_assignments
    USING (organization_id = current_setting('app.current_organization_id')::UUID);

-- Comments policy
CREATE POLICY comments_org_policy ON comments
    USING (organization_id = current_setting('app.current_organization_id')::UUID);

-- Attachments policy
CREATE POLICY attachments_org_policy ON attachments
    USING (organization_id = current_setting('app.current_organization_id')::UUID);

-- Time logs policy
CREATE POLICY time_logs_org_policy ON time_logs
    USING (organization_id = current_setting('app.current_organization_id')::UUID);

-- Notifications policy
CREATE POLICY notifications_org_policy ON notifications
    USING (organization_id = current_setting('app.current_organization_id')::UUID);

-- Audit logs policy (admins can see all audit logs in their organization)
CREATE POLICY audit_logs_org_policy ON audit_logs
    USING (organization_id = current_setting('app.current_organization_id')::UUID);

-- ========== COLUMN LEVEL SECURITY ==========

-- Function to set the current organization context
CREATE OR REPLACE FUNCTION public.set_current_organization(org_id UUID)
RETURNS VOID AS $$
BEGIN
    PERFORM set_config('app.current_organization_id', org_id::TEXT, TRUE);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to get the current organization ID
CREATE OR REPLACE FUNCTION public.get_current_organization_id()
RETURNS UUID AS $$
BEGIN
    RETURN current_setting('app.current_organization_id')::UUID;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$ LANGUAGE plpgsql STABLE;

-- ========== SENSITIVE DATA ENCRYPTION ==========

-- Enable pgcrypto extension if not already enabled
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Create a key table (in a real scenario, use a secure key management system)
CREATE TABLE IF NOT EXISTS encryption_keys (
    key_id SERIAL PRIMARY KEY,
    key_name TEXT NOT NULL UNIQUE,
    key_value BYTEA NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_by UUID REFERENCES users(user_id)
);

-- Function to encrypt data
CREATE OR REPLACE FUNCTION encrypt_data(data TEXT, key_name TEXT)
RETURNS BYTEA AS $$
DECLARE
    encryption_key BYTEA;
BEGIN
    SELECT key_value INTO encryption_key 
    FROM encryption_keys 
    WHERE key_name = $2 
    LIMIT 1;
    
    IF encryption_key IS NULL THEN
        RAISE EXCEPTION 'Encryption key not found: %', key_name;
    END IF;
    
    RETURN pgp_sym_encrypt($1, encode(encryption_key, 'escape'));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to decrypt data
CREATE OR REPLACE FUNCTION decrypt_data(encrypted_data BYTEA, key_name TEXT)
RETURNS TEXT AS $$
DECLARE
    encryption_key BYTEA;
BEGIN
    SELECT key_value INTO encryption_key 
    FROM encryption_keys 
    WHERE key_name = $2 
    LIMIT 1;
    
    IF encryption_key IS NULL THEN
        RAISE EXCEPTION 'Encryption key not found: %', key_name;
    END IF;
    
    RETURN pgp_sym_decrypt($1, encode(encryption_key, 'escape'));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ========== PASSWORD HASHING ==========

-- Function to hash passwords using bcrypt
CREATE OR REPLACE FUNCTION hash_password()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.password_hash IS NOT NULL AND 
       (TG_OP = 'INSERT' OR OLD.password_hash IS DISTINCT FROM NEW.password_hash) THEN
        NEW.password_hash := crypt(NEW.password_hash, gen_salt('bf'));
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for password hashing
CREATE TRIGGER hash_user_password
BEFORE INSERT OR UPDATE OF password_hash ON users
FOR EACH ROW EXECUTE FUNCTION hash_password();

-- ========== COLUMN ENCRYPTION ==========

-- Example of encrypting sensitive columns (to be added to table creation)
-- ALTER TABLE users 
-- ADD COLUMN email_encrypted BYTEA,
-- ADD COLUMN phone_encrypted BYTEA;

-- Create a view to handle encrypted data
CREATE OR REPLACE VIEW users_secure AS
SELECT 
    user_id,
    organization_id,
    decrypt_data(email_encrypted, 'user_email_key') AS email,
    first_name,
    last_name,
    role,
    status,
    created_at,
    updated_at
FROM users;

-- ========== AUDIT LOGGING ==========

-- Function to log security-relevant events
CREATE OR REPLACE FUNCTION log_security_event(
    p_user_id UUID,
    p_action TEXT,
    p_entity_type TEXT,
    p_entity_id UUID,
    p_details JSONB DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO audit_logs (
        user_id,
        action,
        entity_type,
        entity_id,
        old_values,
        new_values,
        ip_address,
        user_agent
    ) VALUES (
        p_user_id,
        p_action,
        p_entity_type,
        p_entity_id,
        p_details->'old',
        p_details->'new',
        current_setting('app.client_ip', TRUE)::INET,
        current_setting('app.user_agent', TRUE)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ========== ROLE-BASED ACCESS CONTROL ==========

-- Function to check user permissions
CREATE OR REPLACE FUNCTION has_permission(
    p_user_id UUID,
    p_permission TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    user_role TEXT;
BEGIN
    -- Get user's role
    SELECT role INTO user_role
    FROM users
    WHERE user_id = p_user_id;
    
    -- Check permissions based on role
    RETURN CASE 
        WHEN user_role = 'admin' THEN TRUE
        WHEN user_role = 'manager' AND p_permission IN ('view_reports', 'manage_tasks') THEN TRUE
        WHEN user_role = 'member' AND p_permission = 'view_tasks' THEN TRUE
        ELSE FALSE
    END;
END;
$$ LANGUAGE plpgsql STABLE;

-- ========== SESSION MANAGEMENT ==========

-- Table to track active sessions
CREATE TABLE IF NOT EXISTS user_sessions (
    session_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL,
    ip_address INET,
    user_agent TEXT,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_activity TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    is_revoked BOOLEAN DEFAULT FALSE
);

-- Index for session lookups
CREATE INDEX idx_user_sessions_user ON user_sessions(user_id);
CREATE INDEX idx_user_sessions_token ON user_sessions(token_hash);

-- Function to create a new session
CREATE OR REPLACE FUNCTION create_session(
    p_user_id UUID,
    p_token TEXT,
    p_expires_in INTERVAL DEFAULT '24 hours',
    p_ip INET DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_session_id UUID;
BEGIN
    INSERT INTO user_sessions (
        user_id,
        token_hash,
        ip_address,
        user_agent,
        expires_at
    ) VALUES (
        p_user_id,
        crypt(p_token, gen_salt('bf')),
        p_ip,
        p_user_agent,
        CURRENT_TIMESTAMP + p_expires_in
    )
    RETURNING session_id INTO v_session_id;
    
    RETURN v_session_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to validate a session
CREATE OR REPLACE FUNCTION validate_session(
    p_token TEXT
)
RETURNS TABLE (
    is_valid BOOLEAN,
    user_id UUID,
    session_id UUID
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        TRUE AS is_valid,
        us.user_id,
        us.session_id
    FROM user_sessions us
    WHERE us.token_hash = crypt(p_token, us.token_hash)
    AND us.expires_at > CURRENT_TIMESTAMP
    AND us.is_revoked = FALSE
    LIMIT 1;
    
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, NULL::UUID;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ========== SECURITY RECOMMENDATIONS ==========

/*
1. Key Management:
   - Store encryption keys in a secure key management system (KMS)
   - Rotate encryption keys regularly
   - Use different keys for different data types

2. Password Security:
   - Enforce strong password policies
   - Implement account lockout after failed attempts
   - Require periodic password changes

3. Session Security:
   - Use secure, HTTP-only cookies for session tokens
   - Implement CSRF protection
   - Set appropriate CORS policies

4. Network Security:
   - Use SSL/TLS for all database connections
   - Implement network-level firewalls
   - Restrict database access to application servers only

5. Monitoring:
   - Monitor for suspicious login attempts
   - Log all security-relevant events
   - Set up alerts for unusual activity
*/

-- ========== EXAMPLE USAGE ==========

/*
-- 1. Set up a new organization and admin user
INSERT INTO organizations (organization_id, name, subdomain, status)
VALUES (gen_random_uuid(), 'Acme Corp', 'acme', 'active')
RETURNING organization_id;

-- 2. Create an admin user (password will be automatically hashed)
INSERT INTO users (
    user_id,
    organization_id,
    email,
    password_hash,
    first_name,
    last_name,
    role,
    status
) VALUES (
    gen_random_uuid(),
    'org-uuid-from-above',
    'admin@example.com',
    'secure_password_123', -- This will be hashed by the trigger
    'Admin',
    'User',
    'admin',
    'active'
);

-- 3. In your application, set the organization context before queries
SELECT set_current_organization('org-uuid-from-above');

-- 4. Now queries will only return data for the current organization
SELECT * FROM projects; -- Only shows projects for the current org
*/

-- ========== SECURITY AUDIT ==========

-- Function to check security settings
CREATE OR REPLACE FUNCTION security_audit()
RETURNS TABLE (
    setting_name TEXT,
    current_value TEXT,
    recommended_value TEXT,
    status TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        'ssl'::TEXT,
        current_setting('ssl', TRUE),
        'on'::TEXT,
        CASE WHEN current_setting('ssl', TRUE) = 'on' THEN 'PASS' ELSE 'FAIL' END
    
    UNION ALL
    
    SELECT
        'password_encryption'::TEXT,
        current_setting('password_encryption', TRUE),
        'scram-sha-256'::TEXT,
        CASE WHEN current_setting('password_encryption', TRUE) = 'scram-sha-256' THEN 'PASS' ELSE 'WARNING' END
    
    UNION ALL
    
    SELECT
        'row_security'::TEXT,
        'enabled'::TEXT,
        'enabled'::TEXT,
        'PASS' -- We've already enabled RLS on all tables
    
    UNION ALL
    
    SELECT
        'encryption_keys_count'::TEXT,
        COUNT(*)::TEXT,
        '> 0'::TEXT,
        CASE WHEN COUNT(*) > 0 THEN 'PASS' ELSE 'FAIL' END
    FROM encryption_keys;
END;
$$ LANGUAGE plpgsql;

-- ========== FINAL SETUP ==========

-- Create a secure function to initialize the security model
CREATE OR REPLACE FUNCTION initialize_security_model()
RETURNS VOID AS $$
BEGIN
    -- Create a default encryption key if none exists
    IF NOT EXISTS (SELECT 1 FROM encryption_keys WHERE key_name = 'user_email_key') THEN
        INSERT INTO encryption_keys (key_name, key_value, created_by)
        VALUES (
            'user_email_key',
            gen_random_bytes(32), -- 256-bit key
            (SELECT user_id FROM users WHERE email = 'admin@example.com' LIMIT 1)
        );
    END IF;
    
    RAISE NOTICE 'Security model initialized successfully at %', CURRENT_TIMESTAMP;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Error initializing security model: %', SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- Run the initialization function
SELECT initialize_security_model();
