-- =============================================
-- Task Management System - Advanced Indexing Strategy
-- Version: 1.0.0
-- Created: 2025-09-11
-- =============================================

-- ========== USER-CENTRIC INDEXES ==========

-- For quick user lookup and authentication
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_users_email 
ON users(email);

-- For organization-specific user queries
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_users_org_status 
ON users(organization_id, status)
WHERE deleted_at IS NULL;

-- For user activity tracking
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_users_last_login 
ON users(last_login_at DESC)
WHERE status = 'active';

-- ========== TASK PERFORMANCE INDEXES ==========

-- For listing user's tasks
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tasks_assigned_to 
ON tasks(assigned_to, status, due_date)
WHERE assigned_to IS NOT NULL;

-- For finding overdue tasks
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tasks_overdue 
ON tasks(organization_id, due_date, status)
WHERE status NOT IN ('done', 'cancelled') 
AND due_date < CURRENT_TIMESTAMP;

-- For project task listings
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tasks_project_status 
ON tasks(project_id, status, priority, due_date)
WHERE project_id IS NOT NULL;

-- For parent-child task relationships
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tasks_parent 
ON tasks(parent_task_id, organization_id)
WHERE parent_task_id IS NOT NULL;

-- ========== FULL-TEXT SEARCH INDEXES ==========

-- Enable full-text search on task titles and descriptions
ALTER TABLE tasks 
ADD COLUMN IF NOT EXISTS search_vector tsvector 
GENERATED ALWAYS AS (
    setweight(to_tsvector('english', COALESCE(title, '')), 'A') ||
    setweight(to_tsvector('english', COALESCE(description, '')), 'B')
) STORED;

-- Create GIN index for fast text search
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tasks_search 
ON tasks USING GIN(search_vector);

-- ========== TIME TRACKING PERFORMANCE ==========

-- For time log reporting by date range
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_time_logs_user_date 
ON time_logs(user_id, date_trunc('day', start_time))
WHERE end_time IS NOT NULL;

-- For project time tracking
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_time_logs_task_project 
ON time_logs(task_id, organization_id);

-- For billing and reporting
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_time_logs_billable 
ON time_logs(organization_id, billable, date_trunc('month', start_time))
WHERE billable = true;

-- ========== COMPOSITE INDEXES ==========

-- For task dashboard queries
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tasks_dashboard 
ON tasks(organization_id, status, priority, due_date) 
WHERE status != 'done';

-- For notification system
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_notifications_user_unread 
ON notifications(user_id, is_read, created_at)
WHERE is_read = false;

-- For audit log queries
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_audit_logs_entity 
ON audit_logs(entity_type, entity_id, created_at DESC);

-- ========== PARTIAL INDEXES ==========

-- For active projects
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_projects_active 
ON projects(organization_id, status)
WHERE status = 'active' AND deleted_at IS NULL;

-- For task assignments
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_task_assignments_active 
ON task_assignments(task_id, user_id)
WHERE organization_id IS NOT NULL;

-- For comment activity
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_comments_recent 
ON comments(task_id, created_at DESC)
WHERE deleted_at IS NULL;

-- ========== REPORTING INDEXES ==========

-- For time tracking reports
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_time_logs_reporting 
ON time_logs(
    organization_id,
    date_trunc('day', start_time),
    billable
) 
WHERE end_time IS NOT NULL;

-- For task completion metrics
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tasks_completion_metrics 
ON tasks(
    organization_id,
    status,
    date_trunc('day', completed_at)
) 
WHERE status = 'done';

-- ========== FUNCTION-BASED INDEXES ==========

-- For case-insensitive email searches
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_users_email_lower 
ON users(lower(email));

-- For date-based queries
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tasks_due_date_quarter 
ON tasks(
    organization_id,
    EXTRACT(QUARTER FROM due_date),
    EXTRACT(YEAR FROM due_date)
) 
WHERE due_date IS NOT NULL;

-- ========== INDEX MAINTENANCE ==========

-- Function to analyze all tables and update statistics
CREATE OR REPLACE FUNCTION analyze_tables()
RETURNS VOID AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT tablename 
        FROM pg_tables 
        WHERE schemaname = 'public'
    LOOP
        EXECUTE format('ANALYZE VERBOSE %I', r.tablename);
        RAISE NOTICE 'Analyzed table: %', r.tablename;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Function to check index usage
CREATE OR REPLACE FUNCTION check_index_usage()
RETURNS TABLE(
    index_name TEXT,
    table_name TEXT,
    index_size TEXT,
    index_scans BIGINT,
    index_scan_ratio NUMERIC
) AS $$
SELECT
    i.indexrelname::TEXT AS index_name,
    t.relname::TEXT AS table_name,
    pg_size_pretty(pg_relation_size(i.indexrelid)) AS index_size,
    COALESCE(idx_scan, 0) AS index_scans,
    ROUND(
        (COALESCE(idx_scan, 0) * 100.0) / 
        NULLIF(COALESCE(idx_scan, 0) + COALESCE(seq_scan, 0), 0),
        2
    ) AS index_scan_ratio
FROM
    pg_stat_user_tables t
    LEFT JOIN pg_stat_user_indexes i ON t.relid = i.relid
    LEFT JOIN pg_index pi ON i.indexrelid = pi.indexrelid
WHERE
    i.indexrelname IS NOT NULL
    AND NOT pi.indisprimary
ORDER BY
    index_scan_ratio ASC,
    pg_relation_size(i.indexrelid) DESC;
$$ LANGUAGE sql;

-- ========== INDEX USAGE EXAMPLES ==========

/*
-- Example 1: Get user's overdue tasks
EXPLAIN ANALYZE
SELECT * FROM tasks 
WHERE assigned_to = 'user-uuid'
AND status NOT IN ('done', 'cancelled')
AND due_date < CURRENT_TIMESTAMP
ORDER BY due_date;

-- Example 2: Search tasks by keyword
EXPLAIN ANALYZE
SELECT * FROM tasks 
WHERE organization_id = 'org-uuid'
AND search_vector @@ websearch_to_tsquery('english', 'urgent bug')
ORDER BY ts_rank(search_vector, websearch_to_tsquery('english', 'urgent bug')) DESC;

-- Example 3: Get time logged by project
EXPLAIN ANALYZE
SELECT 
    p.name as project_name,
    SUM(EXTRACT(EPOCH FROM (tl.end_time - tl.start_time)) / 3600) as hours_logged
FROM time_logs tl
JOIN tasks t ON tl.task_id = t.task_id
JOIN projects p ON t.project_id = p.project_id
WHERE t.organization_id = 'org-uuid'
AND tl.end_time IS NOT NULL
GROUP BY p.name;
*/

-- ========== MONITORING QUERIES ==========

-- Check index usage statistics
/*
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM 
    pg_stat_user_indexes 
ORDER BY 
    idx_scan ASC;
*/

-- Find unused indexes
/*
SELECT 
    schemaname || '.' || tablename AS table_name,
    indexname AS index_name,
    pg_size_pretty(pg_relation_size(quote_ident(schemaname) || '.' || quote_ident(indexname))) AS index_size,
    idx_scan
FROM 
    pg_stat_user_indexes 
WHERE 
    idx_scan = 0
    AND indexname NOT LIKE '%pkey'
ORDER BY 
    pg_relation_size(quote_ident(schemaname) || '.' || quote_ident(indexname)) DESC;
*/

-- Check table bloat
/*
SELECT
    tablename,
    pg_size_pretty(pg_total_relation_size(quote_ident(tablename))) AS total_size,
    pg_size_pretty(pg_relation_size(quote_ident(tablename))) AS table_size,
    pg_size_pretty(pg_total_relation_size(quote_ident(tablename)) - pg_relation_size(quote_ident(tablename))) AS index_size
FROM 
    pg_tables 
WHERE 
    schemaname = 'public'
ORDER BY 
    pg_total_relation_size(quote_ident(tablename)) DESC;
*/
