-- =============================================
-- Task Management System - Data Warehouse Schema
-- Star Schema Design with SCD Type 2 Support
-- Version: 1.0.0
-- Created: 2025-09-11
-- =============================================

-- ========== DIMENSION TABLES ==========

-- Time Dimension (Date Dimension)
CREATE TABLE dim_time (
    time_key SERIAL PRIMARY KEY,
    full_date DATE NOT NULL,
    day_of_week SMALLINT NOT NULL,
    day_name VARCHAR(9) NOT NULL,
    day_of_month SMALLINT NOT NULL,
    day_of_year SMALLINT NOT NULL,
    week_of_year SMALLINT NOT NULL,
    month_number SMALLINT NOT NULL,
    month_name VARCHAR(9) NOT NULL,
    quarter_number SMALLINT NOT NULL,
    year_number INTEGER NOT NULL,
    is_weekend BOOLEAN NOT NULL,
    is_holiday BOOLEAN DEFAULT FALSE,
    holiday_name VARCHAR(50),
    effective_date DATE NOT NULL,
    expiry_date DATE,
    is_current BOOLEAN DEFAULT TRUE,
    UNIQUE (full_date, effective_date)
);

-- Dimension: Users
CREATE TABLE dim_users (
    user_key SERIAL PRIMARY KEY,
    user_id UUID NOT NULL,
    username VARCHAR(100),
    email VARCHAR(255),
    first_name VARCHAR(100),
    last_name VARCHAR(100),
    role VARCHAR(50),
    status VARCHAR(20),
    department VARCHAR(100),
    manager_id UUID,
    hire_date DATE,
    effective_date TIMESTAMP NOT NULL,
    expiry_date TIMESTAMP,
    is_current BOOLEAN DEFAULT TRUE,
    version_number INTEGER DEFAULT 1,
    source_system VARCHAR(50),
    etl_batch_id VARCHAR(100),
    etl_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Dimension: Projects
CREATE TABLE dim_projects (
    project_key SERIAL PRIMARY KEY,
    project_id UUID NOT NULL,
    project_name VARCHAR(255) NOT NULL,
    project_code VARCHAR(50),
    description TEXT,
    status VARCHAR(50) NOT NULL,
    priority VARCHAR(20),
    start_date DATE,
    end_date DATE,
    budget DECIMAL(15, 2),
    client_name VARCHAR(255),
    manager_id UUID,
    effective_date TIMESTAMP NOT NULL,
    expiry_date TIMESTAMP,
    is_current BOOLEAN DEFAULT TRUE,
    version_number INTEGER DEFAULT 1,
    source_system VARCHAR(50),
    etl_batch_id VARCHAR(100),
    etl_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Dimension: Task Status
CREATE TABLE dim_task_status (
    status_key SERIAL PRIMARY KEY,
    status_id VARCHAR(50) NOT NULL,
    status_name VARCHAR(100) NOT NULL,
    status_category VARCHAR(50) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    effective_date TIMESTAMP NOT NULL,
    expiry_date TIMESTAMP,
    is_current BOOLEAN DEFAULT TRUE,
    version_number INTEGER DEFAULT 1,
    etl_batch_id VARCHAR(100),
    etl_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (status_id, effective_date)
);

-- Dimension: Priority
CREATE TABLE dim_priority (
    priority_key SERIAL PRIMARY KEY,
    priority_id VARCHAR(50) NOT NULL,
    priority_name VARCHAR(100) NOT NULL,
    priority_level INTEGER NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    effective_date TIMESTAMP NOT NULL,
    expiry_date TIMESTAMP,
    is_current BOOLEAN DEFAULT TRUE,
    version_number INTEGER DEFAULT 1,
    etl_batch_id VARCHAR(100),
    etl_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (priority_id, effective_date)
);

-- ========== FACT TABLES ==========

-- Fact: Tasks
CREATE TABLE fact_tasks (
    task_key BIGSERIAL PRIMARY KEY,
    task_id UUID NOT NULL,
    task_sk VARCHAR(100) NOT NULL,
    project_key INTEGER REFERENCES dim_projects(project_key),
    assigned_to_key INTEGER REFERENCES dim_users(user_key),
    reporter_key INTEGER REFERENCES dim_users(user_key),
    status_key INTEGER REFERENCES dim_task_status(status_key),
    priority_key INTEGER REFERENCES dim_priority(priority_key),
    created_date_key INTEGER REFERENCES dim_time(time_key),
    due_date_key INTEGER REFERENCES dim_time(time_key),
    completed_date_key INTEGER REFERENCES dim_time(time_key),
    title VARCHAR(255) NOT NULL,
    description TEXT,
    estimated_hours DECIMAL(10, 2),
    actual_hours DECIMAL(10, 2),
    story_points NUMERIC(5, 2),
    is_blocked BOOLEAN DEFAULT FALSE,
    block_reason TEXT,
    parent_task_id UUID,
    task_type VARCHAR(50),
    labels TEXT[],
    created_timestamp TIMESTAMP,
    updated_timestamp TIMESTAMP,
    days_open INTEGER,
    days_in_progress INTEGER,
    days_in_review INTEGER,
    days_completed INTEGER,
    is_overdue BOOLEAN,
    days_overdue INTEGER,
    completion_ratio DECIMAL(5, 2),
    etl_batch_id VARCHAR(100),
    etl_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (task_id, created_date_key)
);

-- Fact: Time Logs
CREATE TABLE fact_time_logs (
    time_log_key BIGSERIAL PRIMARY KEY,
    time_log_id UUID NOT NULL,
    task_key INTEGER REFERENCES fact_tasks(task_key),
    user_key INTEGER REFERENCES dim_users(user_key),
    project_key INTEGER REFERENCES dim_projects(project_key),
    date_key INTEGER REFERENCES dim_time(time_key),
    start_time_key INTEGER REFERENCES dim_time(time_key),
    end_time_key INTEGER REFERENCES dim_time(time_key),
    start_timestamp TIMESTAMP NOT NULL,
    end_timestamp TIMESTAMP,
    duration_minutes DECIMAL(10, 2) NOT NULL,
    duration_hours DECIMAL(10, 2) GENERATED ALWAYS AS (duration_minutes / 60.0) STORED,
    billable_hours DECIMAL(10, 2),
    billing_rate DECIMAL(15, 2),
    billing_amount DECIMAL(15, 2),
    is_billable BOOLEAN DEFAULT FALSE,
    description TEXT,
    activity_type VARCHAR(50),
    approval_status VARCHAR(20),
    approved_by INTEGER REFERENCES dim_users(user_key),
    approval_timestamp TIMESTAMP,
    etl_batch_id VARCHAR(100),
    etl_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Fact: Task History (for tracking state changes)
CREATE TABLE fact_task_history (
    history_key BIGSERIAL PRIMARY KEY,
    task_key INTEGER REFERENCES fact_tasks(task_key),
    changed_by_key INTEGER REFERENCES dim_users(user_key),
    changed_date_key INTEGER REFERENCES dim_time(time_key),
    changed_timestamp TIMESTAMP NOT NULL,
    field_changed VARCHAR(50) NOT NULL,
    old_value TEXT,
    new_value TEXT,
    change_type VARCHAR(20) NOT NULL, -- INSERT, UPDATE, DELETE
    change_description TEXT,
    etl_batch_id VARCHAR(100),
    etl_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ========== BRIDGE TABLES ==========

-- Bridge: Task Assignees (for many-to-many relationship)
CREATE TABLE bridge_task_assignees (
    task_key INTEGER REFERENCES fact_tasks(task_key),
    user_key INTEGER REFERENCES dim_users(user_key),
    is_primary BOOLEAN DEFAULT FALSE,
    assignment_date_key INTEGER REFERENCES dim_time(time_key),
    assignment_timestamp TIMESTAMP,
    etl_batch_id VARCHAR(100),
    etl_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (task_key, user_key)
);

-- ========== AGGREGATE TABLES ==========

-- Aggregate: Daily Task Metrics
CREATE TABLE agg_daily_task_metrics (
    date_key INTEGER REFERENCES dim_time(time_key),
    project_key INTEGER REFERENCES dim_projects(project_key),
    status_key INTEGER REFERENCES dim_task_status(status_key),
    priority_key INTEGER REFERENCES dim_priority(priority_key),
    task_count INTEGER DEFAULT 0,
    open_tasks INTEGER DEFAULT 0,
    in_progress_tasks INTEGER DEFAULT 0,
    completed_tasks INTEGER DEFAULT 0,
    blocked_tasks INTEGER DEFAULT 0,
    overdue_tasks INTEGER DEFAULT 0,
    avg_days_open DECIMAL(10, 2),
    avg_days_to_complete DECIMAL(10, 2),
    total_story_points INTEGER,
    completed_story_points INTEGER,
    completion_ratio DECIMAL(5, 2),
    etl_batch_id VARCHAR(100),
    etl_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (date_key, project_key, status_key, priority_key)
);

-- Aggregate: User Workload
CREATE TABLE agg_user_workload (
    date_key INTEGER REFERENCES dim_time(time_key),
    user_key INTEGER REFERENCES dim_users(user_key),
    project_key INTEGER REFERENCES dim_projects(project_key),
    assigned_tasks INTEGER DEFAULT 0,
    completed_tasks INTEGER DEFAULT 0,
    open_tasks INTEGER DEFAULT 0,
    in_progress_tasks INTEGER DEFAULT 0,
    overdue_tasks INTEGER DEFAULT 0,
    total_hours_logged DECIMAL(10, 2),
    avg_hours_per_task DECIMAL(10, 2),
    billable_hours DECIMAL(10, 2),
    non_billable_hours DECIMAL(10, 2),
    utilization_percentage DECIMAL(5, 2),
    etl_batch_id VARCHAR(100),
    etl_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (date_key, user_key, project_key)
);

-- ========== ETL PROCESSING TABLES ==========

-- ETL Batch Log
CREATE TABLE etl_batch_log (
    batch_id VARCHAR(100) PRIMARY KEY,
    batch_start_time TIMESTAMP NOT NULL,
    batch_end_time TIMESTAMP,
    status VARCHAR(20) NOT NULL,
    source_system VARCHAR(50) NOT NULL,
    records_processed INTEGER,
    records_inserted INTEGER,
    records_updated INTEGER,
    records_failed INTEGER,
    error_message TEXT,
    created_by VARCHAR(100),
    created_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ETL Error Log
CREATE TABLE etl_error_log (
    error_id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(100) REFERENCES etl_batch_log(batch_id),
    error_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    error_severity VARCHAR(20),
    error_code VARCHAR(50),
    error_message TEXT,
    source_table VARCHAR(100),
    source_key VARCHAR(255),
    error_data JSONB,
    resolved BOOLEAN DEFAULT FALSE,
    resolved_by VARCHAR(100),
    resolved_timestamp TIMESTAMP,
    resolution_notes TEXT
);

-- ETL Audit Log
CREATE TABLE etl_audit_log (
    audit_id BIGSERIAL PRIMARY KEY,
    batch_id VARCHAR(100) REFERENCES etl_batch_log(batch_id),
    table_name VARCHAR(100) NOT NULL,
    operation_type VARCHAR(20) NOT NULL, -- INSERT, UPDATE, DELETE, TRUNCATE
    records_affected INTEGER,
    start_time TIMESTAMP NOT NULL,
    end_time TIMESTAMP,
    status VARCHAR(20) NOT NULL,
    error_message TEXT,
    execution_time_seconds DECIMAL(10, 2)
);

-- ========== INDEXES ==========

-- Dimension Indexes
CREATE INDEX idx_dim_users_user_id ON dim_users(user_id);
CREATE INDEX idx_dim_users_email ON dim_users(email);
CREATE INDEX idx_dim_projects_project_id ON dim_projects(project_id);
CREATE INDEX idx_dim_task_status_status_id ON dim_task_status(status_id);
CREATE INDEX idx_dim_priority_priority_id ON dim_priority(priority_id);

-- Fact Table Indexes
CREATE INDEX idx_fact_tasks_task_id ON fact_tasks(task_id);
CREATE INDEX idx_fact_tasks_project_key ON fact_tasks(project_key);
CREATE INDEX idx_fact_tasks_assigned_to_key ON fact_tasks(assigned_to_key);
CREATE INDEX idx_fact_tasks_status_key ON fact_tasks(status_key);
CREATE INDEX idx_fact_tasks_created_date_key ON fact_tasks(created_date_key);
CREATE INDEX idx_fact_tasks_due_date_key ON fact_tasks(due_date_key);
CREATE INDEX idx_fact_tasks_completed_date_key ON fact_tasks(completed_date_key);

CREATE INDEX idx_fact_time_logs_task_key ON fact_time_logs(task_key);
CREATE INDEX idx_fact_time_logs_user_key ON fact_time_logs(user_key);
CREATE INDEX idx_fact_time_logs_project_key ON fact_time_logs(project_key);
CREATE INDEX idx_fact_time_logs_date_key ON fact_time_logs(date_key);
CREATE INDEX idx_fact_time_logs_start_timestamp ON fact_time_logs(start_timestamp);

-- Aggregate Table Indexes
CREATE INDEX idx_agg_daily_task_metrics_date ON agg_daily_task_metrics(date_key);
CREATE INDEX idx_agg_daily_task_metrics_project ON agg_daily_task_metrics(project_key);
CREATE INDEX idx_agg_user_workload_date_user ON agg_user_workload(date_key, user_key);

-- ========== PARTITIONING ==========

-- Partition fact_time_logs by month
CREATE TABLE fact_time_logs_y2023m01 PARTITION OF fact_time_logs 
    FOR VALUES FROM ('2023-01-01') TO ('2023-02-01');

-- Create similar partitions for other months as needed
-- This would typically be done through a maintenance function

-- ========== COMMENTS ==========

COMMENT ON TABLE dim_time IS 'Time dimension table with one row per day for reporting';
COMMENT ON TABLE dim_users IS 'User dimension with SCD Type 2 support for tracking changes';
COMMENT ON TABLE dim_projects IS 'Project dimension with SCD Type 2 support';
COMMENT ON TABLE fact_tasks IS 'Fact table for task metrics and attributes';
COMMENT ON TABLE fact_time_logs IS 'Fact table for time tracking data';
COMMENT ON TABLE fact_task_history IS 'Fact table for tracking task changes over time';

-- ========== GRANTS ==========

-- Grant read access to reporting role
GRANT SELECT ON ALL TABLES IN SCHEMA public TO reporting_role;

-- Grant read/write access to ETL role
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO etl_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO etl_role;
