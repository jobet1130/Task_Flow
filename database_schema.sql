-- =============================================
-- Task Management System Database Schema
-- Version: 1.0.0
-- Created: 2025-09-11
-- Last Updated: 2025-09-11
-- =============================================

-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ========== CORE TABLES ==========

CREATE TABLE organizations (
    organization_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    subdomain VARCHAR(100) UNIQUE NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deleted')),
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

CREATE TABLE users (
    user_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    email VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    role VARCHAR(50) NOT NULL CHECK (role IN ('admin', 'manager', 'member', 'guest')),
    status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'suspended')),
    email_verified_at TIMESTAMP WITH TIME ZONE,
    last_login_at TIMESTAMP WITH TIME ZONE,
    preferences JSONB DEFAULT '{}'::jsonb,
    created_by UUID REFERENCES users(user_id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_org_email UNIQUE (organization_id, email)
);

CREATE TABLE projects (
    project_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    status VARCHAR(50) NOT NULL DEFAULT 'planning' CHECK (status IN ('planning', 'active', 'on_hold', 'completed', 'cancelled')),
    start_date DATE,
    due_date DATE,
    budget DECIMAL(12, 2),
    custom_fields JSONB DEFAULT '{}'::jsonb,
    created_by UUID NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- ========== TASK MANAGEMENT ==========

CREATE TABLE tasks (
    task_id UUID DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL,
    project_id UUID REFERENCES projects(project_id) ON DELETE SET NULL,
    parent_task_id UUID,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    status VARCHAR(50) NOT NULL DEFAULT 'todo' CHECK (status IN ('backlog', 'todo', 'in_progress', 'in_review', 'done')),
    priority VARCHAR(20) NOT NULL DEFAULT 'medium' CHECK (priority IN ('critical', 'high', 'medium', 'low')),
    due_date TIMESTAMP WITH TIME ZONE,
    estimated_hours DECIMAL(5,2),
    actual_hours DECIMAL(10,2) DEFAULT 0,
    custom_fields JSONB DEFAULT '{}'::jsonb,
    created_by UUID NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    assigned_to UUID REFERENCES users(user_id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP WITH TIME ZONE,
    PRIMARY KEY (organization_id, task_id),
    CONSTRAINT fk_org_task FOREIGN KEY (organization_id) REFERENCES organizations(organization_id) ON DELETE CASCADE,
    CONSTRAINT fk_parent_task FOREIGN KEY (organization_id, parent_task_id) 
        REFERENCES tasks(organization_id, task_id) ON DELETE CASCADE
) PARTITION BY HASH (organization_id);

-- Create task partitions (4 partitions for distribution)
CREATE TABLE tasks_p0 PARTITION OF tasks FOR VALUES WITH (modulus 4, remainder 0);
CREATE TABLE tasks_p1 PARTITION OF tasks FOR VALUES WITH (modulus 4, remainder 1);
CREATE TABLE tasks_p2 PARTITION OF tasks FOR VALUES WITH (modulus 4, remainder 2);
CREATE TABLE tasks_p3 PARTITION OF tasks FOR VALUES WITH (modulus 4, remainder 3);

CREATE TABLE task_assignments (
    task_id UUID NOT NULL,
    organization_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    assigned_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    assigned_by UUID NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    role VARCHAR(20) NOT NULL DEFAULT 'assignee' CHECK (role IN ('assignee', 'reviewer', 'watcher')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (task_id, organization_id, user_id),
    CONSTRAINT fk_task_assignment FOREIGN KEY (organization_id, task_id) 
        REFERENCES tasks(organization_id, task_id) ON DELETE CASCADE
);

-- ========== COLLABORATION ==========

CREATE TABLE comments (
    comment_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL,
    task_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    parent_comment_id UUID REFERENCES comments(comment_id) ON DELETE CASCADE,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT fk_task_comment FOREIGN KEY (organization_id, task_id) 
        REFERENCES tasks(organization_id, task_id) ON DELETE CASCADE
);

-- ========== FILE MANAGEMENT ==========

CREATE TABLE attachments (
    attachment_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    task_id UUID NOT NULL,
    file_name VARCHAR(255) NOT NULL,
    file_type VARCHAR(50),
    file_size BIGINT NOT NULL,
    storage_key VARCHAR(255) NOT NULL,
    mime_type VARCHAR(100),
    uploaded_by UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT fk_task_attachment FOREIGN KEY (organization_id, task_id) 
        REFERENCES tasks(organization_id, task_id) ON DELETE CASCADE
);

-- ========== TIME TRACKING ==========

CREATE TABLE time_logs (
    log_id UUID DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL,
    task_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE,
    duration_minutes INTEGER GENERATED ALWAYS AS (
        EXTRACT(EPOCH FROM (end_time - start_time))::INTEGER / 60
    ) STORED,
    description TEXT,
    billable BOOLEAN DEFAULT true,
    hourly_rate DECIMAL(10,2),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (organization_id, log_id, date_trunc('day', start_time)),
    CONSTRAINT fk_task_time_log FOREIGN KEY (organization_id, task_id) 
        REFERENCES tasks(organization_id, task_id) ON DELETE CASCADE,
    CONSTRAINT chk_valid_time_range CHECK (end_time IS NULL OR end_time >= start_time)
) PARTITION BY RANGE (date_trunc('day', start_time));

-- Create time_logs partitions for the next 12 months
CREATE TABLE time_logs_y2023m09 PARTITION OF time_logs
    FOR VALUES FROM ('2023-09-01') TO ('2023-10-01');
-- Add more monthly partitions as needed

-- ========== NOTIFICATION SYSTEM ==========

CREATE TABLE notifications (
    notification_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    type VARCHAR(50) NOT NULL,
    title VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,
    metadata JSONB DEFAULT '{}'::jsonb,
    is_read BOOLEAN DEFAULT false,
    read_at TIMESTAMP WITH TIME ZONE,
    scheduled_for TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ========== AUDIT LOGGING ==========

CREATE TABLE audit_logs (
    log_id BIGSERIAL PRIMARY KEY,
    organization_id UUID REFERENCES organizations(organization_id) ON DELETE SET NULL,
    user_id UUID REFERENCES users(user_id) ON DELETE SET NULL,
    action VARCHAR(50) NOT NULL CHECK (action IN ('CREATE', 'UPDATE', 'DELETE', 'LOGIN', 'LOGOUT', 'PERMISSION_CHANGE')),
    entity_type VARCHAR(50) NOT NULL,
    entity_id UUID,
    old_values JSONB,
    new_values JSONB,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
) PARTITION BY RANGE (created_at);

-- Create audit_logs partitions by month
CREATE TABLE audit_logs_y2023m09 PARTITION OF audit_logs
    FOR VALUES FROM ('2023-09-01') TO ('2023-10-01');

-- ========== TAGGING SYSTEM ==========

CREATE TABLE tags (
    tag_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(organization_id) ON DELETE CASCADE,
    name VARCHAR(50) NOT NULL,
    color_code VARCHAR(7),
    type VARCHAR(50) NOT NULL CHECK (type IN ('CATEGORY', 'PRIORITY', 'STATUS', 'CUSTOM')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT uq_org_tag_name_type UNIQUE (organization_id, name, type)
);

CREATE TABLE task_tags (
    task_id UUID NOT NULL,
    organization_id UUID NOT NULL,
    tag_id UUID NOT NULL REFERENCES tags(tag_id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (task_id, organization_id, tag_id),
    CONSTRAINT fk_task_tag FOREIGN KEY (organization_id, task_id) 
        REFERENCES tasks(organization_id, task_id) ON DELETE CASCADE
);

-- ========== INDEXES ==========

-- Users
CREATE INDEX idx_users_organization ON users(organization_id);
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_users_status ON users(status);

-- Projects
CREATE INDEX idx_projects_organization ON projects(organization_id);
CREATE INDEX idx_projects_status ON projects(status);
CREATE INDEX idx_projects_dates ON projects(start_date, due_date);
CREATE INDEX idx_projects_created_by ON projects(created_by);

-- Tasks
CREATE INDEX idx_tasks_project ON tasks(project_id);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_priority ON tasks(priority);
CREATE INDEX idx_tasks_dates ON tasks(due_date, created_at);
CREATE INDEX idx_tasks_assignee ON tasks(assigned_to) WHERE assigned_to IS NOT NULL;
CREATE INDEX idx_tasks_created_by ON tasks(created_by);

-- Comments
CREATE INDEX idx_comments_task ON comments(organization_id, task_id);
CREATE INDEX idx_comments_user ON comments(user_id);
CREATE INDEX idx_comments_created ON comments(created_at);

-- Attachments
CREATE INDEX idx_attachments_task ON attachments(organization_id, task_id);
CREATE INDEX idx_attachments_uploaded_by ON attachments(uploaded_by);

-- Time Logs
CREATE INDEX idx_time_logs_user ON time_logs(organization_id, user_id);
CREATE INDEX idx_time_logs_task ON time_logs(organization_id, task_id);
CREATE INDEX idx_time_logs_date ON time_logs USING BRIN (start_time);

-- Notifications
CREATE INDEX idx_notifications_user ON notifications(organization_id, user_id, is_read, created_at);
CREATE INDEX idx_notifications_scheduled ON notifications(scheduled_for) WHERE NOT is_read;

-- Audit Logs
CREATE INDEX idx_audit_logs_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_logs_user ON audit_logs(organization_id, user_id, created_at);
CREATE INDEX idx_audit_logs_created ON audit_logs USING BRIN (created_at);

-- Tags
CREATE INDEX idx_tags_organization ON tags(organization_id, type);
CREATE INDEX idx_task_tags_tag ON task_tags(organization_id, tag_id);

-- ========== FUNCTIONS ==========

-- Function to update updated_at timestamps
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create triggers for updated_at
DO $$
DECLARE
    t record;
BEGIN
    FOR t IN 
        SELECT table_schema, table_name 
        FROM information_schema.tables 
        WHERE table_schema = 'public' 
        AND table_type = 'BASE TABLE'
        AND table_name IN ('users', 'projects', 'tasks', 'comments', 'attachments', 'time_logs')
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS update_%s_modtime ON %I.%I', 
                      t.table_name, t.table_schema, t.table_name);
        EXECUTE format('CREATE TRIGGER update_%s_modtime
                      BEFORE UPDATE ON %I.%I
                      FOR EACH ROW EXECUTE FUNCTION update_modified_column()',
                      t.table_name, t.table_schema, t.table_name);
    END LOOP;
END;
$$;

-- Function to create monthly partitions for time_logs
CREATE OR REPLACE FUNCTION create_time_logs_partition()
RETURNS TRIGGER AS $$
DECLARE
    partition_date DATE;
    partition_name TEXT;
    partition_start DATE;
    partition_end DATE;
    i INT;
BEGIN
    -- Create partitions for the next 12 months
    FOR i IN 0..11 LOOP
        partition_date := date_trunc('month', CURRENT_DATE + (i || ' months')::interval);
        partition_name := 'time_logs_y' || to_char(partition_date, 'YYYY"m"MM');
        partition_start := partition_date;
        partition_end := partition_date + interval '1 month';
        
        IF NOT EXISTS (
            SELECT 1 
            FROM pg_tables 
            WHERE schemaname = 'public' 
            AND tablename = partition_name
        ) THEN
            EXECUTE format(
                'CREATE TABLE %I PARTITION OF time_logs FOR VALUES FROM (%L) TO (%L)',
                partition_name,
                partition_start,
                partition_end
            );
        END IF;
    END LOOP;
    
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Create monthly partitions for audit_logs
CREATE OR REPLACE FUNCTION create_audit_logs_partition()
RETURNS TRIGGER AS $$
DECLARE
    partition_date DATE;
    partition_name TEXT;
    partition_start DATE;
    partition_end DATE;
    i INT;
BEGIN
    -- Create partitions for the next 12 months
    FOR i IN 0..11 LOOP
        partition_date := date_trunc('month', CURRENT_DATE + (i || ' months')::interval);
        partition_name := 'audit_logs_y' || to_char(partition_date, 'YYYY"m"MM');
        partition_start := partition_date;
        partition_end := partition_date + interval '1 month';
        
        IF NOT EXISTS (
            SELECT 1 
            FROM pg_tables 
            WHERE schemaname = 'public' 
            AND tablename = partition_name
        ) THEN
            EXECUTE format(
                'CREATE TABLE %I PARTITION OF audit_logs FOR VALUES FROM (%L) TO (%L)',
                partition_name,
                partition_start,
                partition_end
            );
        END IF;
    END LOOP;
    
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Create event triggers for partition maintenance
CREATE OR REPLACE FUNCTION create_partitions()
RETURNS event_trigger AS $$
BEGIN
    PERFORM create_time_logs_partition();
    PERFORM create_audit_logs_partition();
END;
$$ LANGUAGE plpgsql;

-- Create event trigger for partition maintenance
CREATE EVENT TRIGGER IF NOT EXISTS on_create_table_trigger
ON ddl_command_end
WHEN TAG IN ('CREATE TABLE')
EXECUTE FUNCTION create_partitions();

-- ========== VIEWS ==========

-- View for task metrics
CREATE OR REPLACE VIEW task_metrics AS
SELECT 
    t.organization_id,
    t.project_id,
    p.name AS project_name,
    COUNT(*) FILTER (WHERE t.status = 'todo') AS todo_count,
    COUNT(*) FILTER (WHERE t.status = 'in_progress') AS in_progress_count,
    COUNT(*) FILTER (WHERE t.status = 'in_review') AS in_review_count,
    COUNT(*) FILTER (WHERE t.status = 'done') AS done_count,
    COUNT(*) FILTER (WHERE t.due_date < CURRENT_DATE AND t.status != 'done') AS overdue_count,
    SUM(COALESCE(t.estimated_hours, 0)) AS total_estimated_hours,
    SUM(COALESCE(t.actual_hours, 0)) AS total_actual_hours
FROM 
    tasks t
LEFT JOIN 
    projects p ON t.project_id = p.project_id
GROUP BY 
    t.organization_id, t.project_id, p.name;

-- View for user workload
CREATE OR REPLACE VIEW user_workload AS
SELECT 
    u.organization_id,
    u.user_id,
    u.email,
    u.first_name,
    u.last_name,
    COUNT(DISTINCT t.task_id) AS total_tasks,
    COUNT(DISTINCT t.task_id) FILTER (WHERE t.status != 'done') AS active_tasks,
    COUNT(DISTINCT t.task_id) FILTER (WHERE t.due_date < CURRENT_DATE AND t.status != 'done') AS overdue_tasks,
    SUM(COALESCE(t.estimated_hours, 0)) AS total_estimated_hours,
    SUM(COALESCE(tl.duration_minutes, 0)) / 60.0 AS total_logged_hours
FROM 
    users u
LEFT JOIN 
    tasks t ON u.user_id = t.assigned_to
LEFT JOIN 
    time_logs tl ON u.user_id = tl.user_id
GROUP BY 
    u.organization_id, u.user_id, u.email, u.first_name, u.last_name;

-- ========== ROW LEVEL SECURITY ==========

-- Enable RLS on all tables
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE attachments ENABLE ROW LEVEL SECURITY;
ALTER TABLE time_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE task_tags ENABLE ROW LEVEL SECURITY;

-- ========== COMMENTS ==========

COMMENT ON TABLE organizations IS 'Stores organization/tenant information';
COMMENT ON COLUMN organizations.metadata IS 'Flexible JSON field for organization-specific settings and configurations';

COMMENT ON TABLE users IS 'Stores user accounts and authentication information';
COMMENT ON COLUMN users.preferences IS 'User-specific preferences stored as JSON';

COMMENT ON TABLE projects IS 'Stores project information and metadata';
COMMENT ON COLUMN projects.custom_fields IS 'Project-specific custom fields stored as JSON';

COMMENT ON TABLE tasks IS 'Stores task information with partitioning by organization_id';
COMMENT ON COLUMN tasks.custom_fields IS 'Task-specific custom fields stored as JSON';

COMMENT ON TABLE time_logs IS 'Stores time tracking entries with monthly partitioning';
COMMENT ON COLUMN time_logs.duration_minutes IS 'Calculated field based on start_time and end_time';

-- ========== GRANTS ==========

-- Example: Create application roles and grant permissions
DO $$
BEGIN
    -- Create roles if they don't exist
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_reader') THEN
        CREATE ROLE app_reader NOLOGIN;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_writer') THEN
        CREATE ROLE app_writer NOLOGIN;
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_admin') THEN
        CREATE ROLE app_admin BYPASSRLS NOLOGIN;
    END IF;
    
    -- Grant schema usage
    GRANT USAGE ON SCHEMA public TO app_reader, app_writer, app_admin;
    
    -- Grant table permissions
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_reader;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_writer;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO app_admin;
    
    -- Grant sequence permissions
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_writer, app_admin;
    
    -- Grant execute on functions
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO app_writer, app_admin;
    
    -- Default privileges for future objects
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO app_reader;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_writer;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO app_admin;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO app_writer, app_admin;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO app_writer, app_admin;
END;
$$;

-- ========== SAMPLE DATA ==========

-- Uncomment and modify as needed for initial setup
/*
INSERT INTO organizations (organization_id, name, subdomain, status)
VALUES 
    ('11111111-1111-1111-1111-111111111111', 'Acme Corp', 'acme', 'active'),
    ('22222222-2222-2222-2222-222222222222', 'Tech Solutions', 'tech', 'active');

-- Add more sample data as needed
*/

-- ========== DATABASE MAINTENANCE ==========

-- Create a function to create monthly partitions
CREATE OR REPLACE FUNCTION create_monthly_partitions()
RETURNS VOID AS $$
BEGIN
    -- Call partition creation functions
    PERFORM create_time_logs_partition();
    PERFORM create_audit_logs_partition();
    
    -- Add more partition creation calls for other partitioned tables if needed
END;
$$ LANGUAGE plpgsql;

-- Schedule partition maintenance (example using pg_cron if available)
-- Uncomment and modify as needed
/*
SELECT cron.schedule('0 0 1 * *', 'SELECT create_monthly_partitions()');
*/

-- ========== END OF SCHEMA ==========

-- Log successful schema creation
DO $$
BEGIN
    RAISE NOTICE 'Task Management System database schema created successfully at %', CURRENT_TIMESTAMP;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Error creating schema: %', SQLERRM;
END;
$$;
