-- =============================================
-- Task Management System - Advanced PostgreSQL Schema
-- Version: 2.0.0
-- Created: 2025-09-11
-- Last Updated: 2025-09-11
-- =============================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ========== CORE TABLES ==========

CREATE TABLE organizations (
    organization_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    subdomain VARCHAR(100) UNIQUE NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'active' 
        CHECK (status IN ('active', 'suspended', 'deleted')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

CREATE TABLE users (
    user_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(organization_id) 
        ON DELETE CASCADE,
    email VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    role VARCHAR(50) NOT NULL 
        CHECK (role IN ('admin', 'manager', 'member', 'guest')),
    status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'active', 'suspended', 'inactive')),
    last_login_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_org_email UNIQUE (organization_id, email)
);

-- ========== PROJECT MANAGEMENT ==========

CREATE TABLE projects (
    project_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(organization_id) 
        ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    status VARCHAR(50) NOT NULL DEFAULT 'planning'
        CHECK (status IN ('planning', 'active', 'on_hold', 'completed', 'cancelled')),
    start_date DATE,
    due_date DATE,
    created_by UUID NOT NULL REFERENCES users(user_id) 
        ON DELETE RESTRICT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE
);

-- ========== TASK MANAGEMENT ==========

-- Main tasks table with partitioning by due_date
CREATE TABLE tasks (
    task_id UUID,
    organization_id UUID NOT NULL,
    project_id UUID REFERENCES projects(project_id) 
        ON DELETE SET NULL,
    parent_task_id UUID,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    status VARCHAR(50) NOT NULL DEFAULT 'todo'
        CHECK (status IN ('backlog', 'todo', 'in_progress', 'in_review', 'done')),
    priority VARCHAR(20) NOT NULL DEFAULT 'medium'
        CHECK (priority IN ('low', 'medium', 'high', 'critical')),
    due_date TIMESTAMP WITH TIME ZONE,
    estimated_hours DECIMAL(5,2),
    actual_hours DECIMAL(10,2) DEFAULT 0,
    created_by UUID NOT NULL REFERENCES users(user_id)
        ON DELETE RESTRICT,
    assigned_to UUID REFERENCES users(user_id)
        ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP WITH TIME ZONE,
    PRIMARY KEY (task_id, due_date),
    CONSTRAINT fk_org_task FOREIGN KEY (organization_id) 
        REFERENCES organizations(organization_id) 
        ON DELETE CASCADE,
    CONSTRAINT fk_parent_task FOREIGN KEY (parent_task_id, due_date) 
        REFERENCES tasks(task_id, due_date) 
        ON DELETE CASCADE
) PARTITION BY RANGE (due_date);

-- Create partitions for tasks (example for 2025-2026)
CREATE TABLE tasks_2025_q1 PARTITION OF tasks
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');
CREATE TABLE tasks_2025_q2 PARTITION OF tasks
    FOR VALUES FROM ('2025-04-01') TO ('2025-07-01');
CREATE TABLE tasks_2025_q3 PARTITION OF tasks
    FOR VALUES FROM ('2025-07-01') TO ('2025-10-01');
CREATE TABLE tasks_2025_q4 PARTITION OF tasks
    FOR VALUES FROM ('2025-10-01') TO ('2026-01-01');

-- Default partition for tasks without due dates
CREATE TABLE tasks_no_date PARTITION OF tasks
    DEFAULT;

-- Task assignments (many-to-many)
CREATE TABLE task_assignments (
    task_id UUID NOT NULL,
    organization_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES users(user_id)
        ON DELETE CASCADE,
    assigned_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    assigned_by UUID NOT NULL REFERENCES users(user_id)
        ON DELETE RESTRICT,
    role VARCHAR(20) NOT NULL DEFAULT 'assignee'
        CHECK (role IN ('assignee', 'reviewer', 'watcher')),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (task_id, organization_id, user_id),
    CONSTRAINT fk_task_assignment FOREIGN KEY (task_id) 
        REFERENCES tasks(task_id) 
        ON DELETE CASCADE
);

-- ========== COLLABORATION ==========

CREATE TABLE comments (
    comment_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL,
    task_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES users(user_id)
        ON DELETE CASCADE,
    content TEXT NOT NULL,
    parent_comment_id UUID REFERENCES comments(comment_id)
        ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT fk_task_comment FOREIGN KEY (task_id) 
        REFERENCES tasks(task_id) 
        ON DELETE CASCADE
);

CREATE TABLE attachments (
    attachment_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL,
    task_id UUID NOT NULL,
    file_name VARCHAR(255) NOT NULL,
    file_path TEXT NOT NULL,
    file_size BIGINT NOT NULL,
    mime_type VARCHAR(100),
    uploaded_by UUID NOT NULL REFERENCES users(user_id)
        ON DELETE CASCADE,
    uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT fk_task_attachment FOREIGN KEY (task_id) 
        REFERENCES tasks(task_id) 
        ON DELETE CASCADE
);

-- ========== TIME TRACKING ==========

-- Time logs with monthly partitioning
CREATE TABLE time_logs (
    log_id UUID,
    organization_id UUID NOT NULL,
    task_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES users(user_id)
        ON DELETE CASCADE,
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE,
    duration_minutes INTEGER GENERATED ALWAYS AS (
        CASE 
            WHEN end_time IS NULL THEN NULL
            ELSE EXTRACT(EPOCH FROM (end_time - start_time))::INTEGER / 60
        END
    ) STORED,
    description TEXT,
    billable BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (log_id, start_time),
    CONSTRAINT fk_task_time_log FOREIGN KEY (task_id) 
        REFERENCES tasks(task_id) 
        ON DELETE CASCADE,
    CONSTRAINT chk_valid_time_range CHECK (
        end_time IS NULL OR end_time >= start_time
    )
) PARTITION BY RANGE (date_trunc('month', start_time));

-- Create time_logs partitions for the next 12 months
DO $$
DECLARE
    month_start DATE;
    month_end DATE;
    partition_name TEXT;
    i INT;
BEGIN
    FOR i IN 0..11 LOOP
        month_start := date_trunc('month', CURRENT_DATE + (i || ' months')::interval);
        month_end := month_start + interval '1 month';
        partition_name := 'time_logs_' || to_char(month_start, 'YYYY_MM');
        
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF time_logs ' ||
            'FOR VALUES FROM (%L) TO (%L)',
            partition_name,
            month_start,
            month_end
        );
    END LOOP;
END $$;

-- ========== NOTIFICATION SYSTEM ==========

CREATE TABLE notifications (
    notification_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(organization_id)
        ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(user_id)
        ON DELETE CASCADE,
    type VARCHAR(50) NOT NULL,
    title VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,
    is_read BOOLEAN DEFAULT false,
    read_at TIMESTAMP WITH TIME ZONE,
    reference_id UUID,
    reference_type VARCHAR(50),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    scheduled_for TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ========== AUDIT LOGGING ==========

CREATE TABLE audit_logs (
    log_id BIGSERIAL,
    organization_id UUID REFERENCES organizations(organization_id)
        ON DELETE SET NULL,
    user_id UUID REFERENCES users(user_id)
        ON DELETE SET NULL,
    action VARCHAR(50) NOT NULL
        CHECK (action IN ('CREATE', 'UPDATE', 'DELETE', 'LOGIN', 'LOGOUT', 'PERMISSION_CHANGE')),
    entity_type VARCHAR(50) NOT NULL,
    entity_id UUID,
    old_values JSONB,
    new_values JSONB,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (log_id, created_at)
) PARTITION BY RANGE (created_at);

-- Create audit_logs partitions for the next 12 months
DO $$
DECLARE
    month_start DATE;
    month_end DATE;
    partition_name TEXT;
    i INT;
BEGIN
    FOR i IN 0..11 LOOP
        month_start := date_trunc('month', CURRENT_DATE + (i || ' months')::interval);
        month_end := month_start + interval '1 month';
        partition_name := 'audit_logs_' || to_char(month_start, 'YYYY_MM');
        
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF audit_logs ' ||
            'FOR VALUES FROM (%L) TO (%L)',
            partition_name,
            month_start,
            month_end
        );
    END LOOP;
END $$;

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
CREATE INDEX idx_tasks_organization ON tasks(organization_id);
CREATE INDEX idx_tasks_project ON tasks(project_id) WHERE project_id IS NOT NULL;
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_priority ON tasks(priority);
CREATE INDEX idx_tasks_assignee ON tasks(assigned_to) WHERE assigned_to IS NOT NULL;
CREATE INDEX idx_tasks_created_by ON tasks(created_by);
CREATE INDEX idx_tasks_due_date ON tasks(due_date);

-- Task Assignments
CREATE INDEX idx_task_assignments_user ON task_assignments(user_id);
CREATE INDEX idx_task_assignments_org ON task_assignments(organization_id);

-- Comments
CREATE INDEX idx_comments_task ON comments(organization_id, task_id);
CREATE INDEX idx_comments_user ON comments(user_id);
CREATE INDEX idx_comments_created ON comments(created_at);

-- Attachments
CREATE INDEX idx_attachments_task ON attachments(organization_id, task_id);
CREATE INDEX idx_attachments_uploaded_by ON attachments(uploaded_by);

-- Time Logs
CREATE INDEX idx_time_logs_user ON time_logs(user_id);
CREATE INDEX idx_time_logs_task ON time_logs(organization_id, task_id);
CREATE INDEX idx_time_logs_date ON time_logs USING BRIN (start_time);

-- Notifications
CREATE INDEX idx_notifications_user ON notifications(user_id, is_read, created_at);
CREATE INDEX idx_notifications_scheduled ON notifications(scheduled_for) WHERE NOT is_read;

-- Audit Logs
CREATE INDEX idx_audit_logs_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_logs_user ON audit_logs(organization_id, user_id, created_at);
CREATE INDEX idx_audit_logs_created ON audit_logs USING BRIN (created_at);

-- ========== FUNCTIONS AND TRIGGERS ==========

-- Function to update updated_at timestamps
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create triggers for updated_at on relevant tables
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
        EXECUTE format('
            DROP TRIGGER IF EXISTS update_%s_modtime ON %I.%I;
            CREATE TRIGGER update_%s_modtime
            BEFORE UPDATE ON %I.%I
            FOR EACH ROW EXECUTE FUNCTION update_modified_column();
        ', t.table_name, t.table_schema, t.table_name, 
           t.table_name, t.table_schema, t.table_name);
    END LOOP;
END $$;

-- Function to create monthly partitions
CREATE OR REPLACE FUNCTION create_monthly_partitions()
RETURNS VOID AS $$
DECLARE
    month_start DATE;
    month_end DATE;
    partition_name TEXT;
    i INT;
BEGIN
    -- Create time_logs partitions for the next 12 months
    FOR i IN 0..11 LOOP
        month_start := date_trunc('month', CURRENT_DATE + (i || ' months')::interval);
        month_end := month_start + interval '1 month';
        partition_name := 'time_logs_' || to_char(month_start, 'YYYY_MM');
        
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF time_logs ' ||
            'FOR VALUES FROM (%L) TO (%L)',
            partition_name,
            month_start,
            month_end
        );
        
        partition_name := 'audit_logs_' || to_char(month_start, 'YYYY_MM');
        
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I PARTITION OF audit_logs ' ||
            'FOR VALUES FROM (%L) TO (%L)',
            partition_name,
            month_start,
            month_end
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Function to create task partitions
CREATE OR REPLACE FUNCTION create_task_partitions()
RETURNS VOID AS $$
DECLARE
    year_start DATE;
    year_end DATE;
    quarter_start DATE;
    quarter_end DATE;
    partition_name TEXT;
    year INT;
    quarter INT;
BEGIN
    -- Create task partitions for current and next year
    FOR year IN EXTRACT(YEAR FROM CURRENT_DATE)..EXTRACT(YEAR FROM CURRENT_DATE) + 1 LOOP
        FOR quarter IN 0..3 LOOP
            quarter_start := make_date(year::int, (quarter * 3) + 1, 1);
            
            IF quarter = 3 THEN
                -- For Q4, set end to start of next year
                quarter_end := make_date(year::int + 1, 1, 1);
            ELSE
                quarter_end := make_date(year::int, ((quarter + 1) * 3) + 1, 1);
            END IF;
            
            partition_name := 'tasks_' || year || '_q' || (quarter + 1);
            
            EXECUTE format(
                'CREATE TABLE IF NOT EXISTS %I PARTITION OF tasks ' ||
                'FOR VALUES FROM (%L) TO (%L)',
                partition_name,
                quarter_start,
                quarter_end
            );
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Create initial partitions
SELECT create_monthly_partitions();
SELECT create_task_partitions();

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

-- ========== SAMPLE DATA ==========

-- Uncomment and modify as needed for initial setup
/*
-- Sample organization
INSERT INTO organizations (organization_id, name, subdomain, status)
VALUES 
    ('11111111-1111-1111-1111-111111111111', 'Acme Corp', 'acme', 'active');

-- Sample admin user
INSERT INTO users (user_id, organization_id, email, password_hash, first_name, last_name, role, status)
VALUES 
    ('22222222-2222-2222-2222-222222222222', 
     '11111111-1111-1111-1111-111111111111', 
     'admin@example.com', 
     crypt('admin123', gen_salt('bf')), 
     'Admin', 'User', 'admin', 'active');
*/

-- ========== FINAL SETUP ==========

-- Create a function to set up the database
CREATE OR REPLACE FUNCTION setup_task_management_db()
RETURNS VOID AS $$
BEGIN
    -- Call all setup functions
    PERFORM create_monthly_partitions();
    PERFORM create_task_partitions();
    
    RAISE NOTICE 'Task Management System database setup completed successfully at %', CURRENT_TIMESTAMP;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Error during database setup: %', SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- Run the setup function
SELECT setup_task_management_db();
