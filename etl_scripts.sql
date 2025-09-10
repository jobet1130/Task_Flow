-- =============================================
-- Task Management System - ETL Scripts
-- Version: 1.0.0
-- Created: 2025-09-11
-- =============================================

-- ========== ETL HELPER FUNCTIONS ==========

-- Function to generate a new batch ID
CREATE OR REPLACE FUNCTION generate_batch_id()
RETURNS VARCHAR(100) AS $$
BEGIN
    RETURN 'BATCH-' || to_char(CURRENT_TIMESTAMP, 'YYYYMMDD-HH24MISS') || '-' || substr(md5(random()::text), 1, 8);
END;
$$ LANGUAGE plpgsql;

-- Function to log ETL batch start
CREATE OR REPLACE FUNCTION log_batch_start(
    p_source_system VARCHAR(50),
    p_created_by VARCHAR(100) DEFAULT 'ETL_PROCESS'
) 
RETURNS VARCHAR(100) AS $$
DECLARE
    v_batch_id VARCHAR(100);
BEGIN
    v_batch_id := generate_batch_id();
    
    INSERT INTO etl_batch_log (
        batch_id,
        batch_start_time,
        status,
        source_system,
        created_by
    ) VALUES (
        v_batch_id,
        CURRENT_TIMESTAMP,
        'RUNNING',
        p_source_system,
        p_created_by
    );
    
    RETURN v_batch_id;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Error starting ETL batch: %', SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- Function to log ETL batch end
CREATE OR REPLACE FUNCTION log_batch_end(
    p_batch_id VARCHAR(100),
    p_status VARCHAR(20),
    p_records_processed INTEGER DEFAULT NULL,
    p_records_inserted INTEGER DEFAULT NULL,
    p_records_updated INTEGER DEFAULT NULL,
    p_records_failed INTEGER DEFAULT NULL,
    p_error_message TEXT DEFAULT NULL
) 
RETURNS VOID AS $$
BEGIN
    UPDATE etl_batch_log
    SET 
        batch_end_time = CURRENT_TIMESTAMP,
        status = p_status,
        records_processed = COALESCE(p_records_processed, records_processed),
        records_inserted = COALESCE(p_records_inserted, records_inserted),
        records_updated = COALESCE(p_records_updated, records_updated),
        records_failed = COALESCE(p_records_failed, records_failed),
        error_message = p_error_message
    WHERE batch_id = p_batch_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Batch ID % not found', p_batch_id;
    END IF;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Error ending ETL batch: %', SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- Function to log ETL error
CREATE OR REPLACE FUNCTION log_etl_error(
    p_batch_id VARCHAR(100),
    p_error_severity VARCHAR(20),
    p_error_code VARCHAR(50),
    p_error_message TEXT,
    p_source_table VARCHAR(100) DEFAULT NULL,
    p_source_key VARCHAR(255) DEFAULT NULL,
    p_error_data JSONB DEFAULT NULL
) 
RETURNS BIGINT AS $$
DECLARE
    v_error_id BIGINT;
BEGIN
    INSERT INTO etl_error_log (
        batch_id,
        error_severity,
        error_code,
        error_message,
        source_table,
        source_key,
        error_data
    ) VALUES (
        p_batch_id,
        p_error_severity,
        p_error_code,
        p_error_message,
        p_source_table,
        p_source_key,
        p_error_data
    )
    RETURNING error_id INTO v_error_id;
    
    RETURN v_error_id;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Error logging ETL error: %', SQLERRM;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Function to log ETL audit
CREATE OR REPLACE FUNCTION log_etl_audit(
    p_batch_id VARCHAR(100),
    p_table_name VARCHAR(100),
    p_operation_type VARCHAR(20),
    p_status VARCHAR(20),
    p_records_affected INTEGER DEFAULT NULL,
    p_start_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    p_end_time TIMESTAMP DEFAULT NULL,
    p_error_message TEXT DEFAULT NULL
) 
RETURNS BIGINT AS $$
DECLARE
    v_audit_id BIGINT;
    v_execution_time_seconds DECIMAL(10, 2);
BEGIN
    -- Calculate execution time in seconds
    IF p_end_time IS NOT NULL AND p_start_time IS NOT NULL THEN
        v_execution_time_seconds := EXTRACT(EPOCH FROM (p_end_time - p_start_time));
    END IF;
    
    INSERT INTO etl_audit_log (
        batch_id,
        table_name,
        operation_type,
        records_affected,
        start_time,
        end_time,
        status,
        error_message,
        execution_time_seconds
    ) VALUES (
        p_batch_id,
        p_table_name,
        p_operation_type,
        p_records_affected,
        p_start_time,
        COALESCE(p_end_time, CURRENT_TIMESTAMP),
        p_status,
        p_error_message,
        v_execution_time_seconds
    )
    RETURNING audit_id INTO v_audit_id;
    
    RETURN v_audit_id;
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Error logging ETL audit: %', SQLERRM;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- ========== DIMENSION LOADING ==========

-- Load Time Dimension (one-time load)
CREATE OR REPLACE PROCEDURE load_dim_time()
LANGUAGE plpgsql
AS $$
DECLARE
    v_start_date DATE := '2020-01-01';
    v_end_date DATE := '2030-12-31';
    v_current_date DATE;
    v_holidays TEXT[] := ARRAY[
        '2023-01-01', '2023-01-16', '2023-02-20', '2023-05-29', '2023-07-04',
        '2023-09-04', '2023-10-09', '2023-11-10', '2023-11-23', '2023-12-25'
        -- Add more holidays as needed
    ];
    v_holiday_name TEXT;
    v_is_holiday BOOLEAN;
    v_holiday_names JSONB := '{
        "2023-01-01": "New Year\'s Day",
        "2023-01-16": "Martin Luther King Jr. Day",
        "2023-02-20": "Presidents\' Day",
        "2023-05-29": "Memorial Day",
        "2023-07-04": "Independence Day",
        "2023-09-04": "Labor Day",
        "2023-10-09": "Columbus Day",
        "2023-11-10": "Veterans Day",
        "2023-11-23": "Thanksgiving Day",
        "2023-12-25": "Christmas Day"
    }';
    v_batch_id VARCHAR(100);
    v_audit_id BIGINT;
    v_start_time TIMESTAMP;
    v_count INTEGER;
BEGIN
    -- Start batch
    v_batch_id := log_batch_start('DIM_TIME_LOAD', 'ETL_PROCESS');
    v_start_time := CURRENT_TIMESTAMP;
    
    BEGIN
        -- Truncate and reload time dimension
        TRUNCATE TABLE dim_time;
        
        -- Generate dates
        v_current_date := v_start_date;
        WHILE v_current_date <= v_end_date LOOP
            -- Check if current date is a holiday
            v_is_holiday := v_current_date::TEXT = ANY(v_holidays);
            v_holiday_name := NULL;
            
            IF v_is_holiday THEN
                v_holiday_name := v_holiday_names->>v_current_date::TEXT;
            END IF;
            
            -- Insert into time dimension
            INSERT INTO dim_time (
                full_date,
                day_of_week,
                day_name,
                day_of_month,
                day_of_year,
                week_of_year,
                month_number,
                month_name,
                quarter_number,
                year_number,
                is_weekend,
                is_holiday,
                holiday_name,
                effective_date,
                expiry_date,
                is_current
            ) VALUES (
                v_current_date,
                EXTRACT(DOW FROM v_current_date)::INTEGER,
                TO_CHAR(v_current_date, 'Day'),
                EXTRACT(DAY FROM v_current_date)::INTEGER,
                EXTRACT(DOY FROM v_current_date)::INTEGER,
                EXTRACT(WEEK FROM v_current_date)::INTEGER,
                EXTRACT(MONTH FROM v_current_date)::INTEGER,
                TO_CHAR(v_current_date, 'Month'),
                EXTRACT(QUARTER FROM v_current_date)::INTEGER,
                EXTRACT(YEAR FROM v_current_date)::INTEGER,
                EXTRACT(DOW FROM v_current_date) IN (0, 6), -- 0=Sunday, 6=Saturday
                v_is_holiday,
                v_holiday_name,
                v_current_date,
                NULL,
                TRUE
            );
            
            v_current_date := v_current_date + INTERVAL '1 day';
        END LOOP;
        
        -- Log success
        GET DIAGNOSTICS v_count = ROW_COUNT;
        v_audit_id := log_etl_audit(
            v_batch_id,
            'dim_time',
            'LOAD',
            'COMPLETED',
            v_count,
            v_start_time,
            CURRENT_TIMESTAMP
        );
        
        -- Update batch log
        PERFORM log_batch_end(
            v_batch_id,
            'COMPLETED',
            v_count,  -- records_processed
            v_count,  -- records_inserted
            0,        -- records_updated
            0         -- records_failed
        );
        
    EXCEPTION WHEN OTHERS THEN
        -- Log error
        PERFORM log_etl_error(
            v_batch_id,
            'ERROR',
            SQLSTATE,
            SQLERRM,
            'dim_time',
            NULL,
            jsonb_build_object('error_context', 'Error in load_dim_time')
        );
        
        -- Update audit log
        PERFORM log_etl_audit(
            v_batch_id,
            'dim_time',
            'LOAD',
            'FAILED',
            NULL,
            v_start_time,
            CURRENT_TIMESTAMP,
            SQLERRM
        );
        
        -- Update batch log
        PERFORM log_batch_end(
            v_batch_id,
            'FAILED',
            0,  -- records_processed
            0,  -- records_inserted
            0,  -- records_updated
            0,  -- records_failed
            SQLERRM
        );
        
        RAISE;
    END;
END;
$$;

-- Load Users Dimension (SCD Type 2)
CREATE OR REPLACE PROCEDURE load_dim_users()
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch_id VARCHAR(100);
    v_audit_id BIGINT;
    v_start_time TIMESTAMP;
    v_count_inserted INTEGER := 0;
    v_count_updated INTEGER := 0;
    v_count_expired INTEGER := 0;
    v_count_unchanged INTEGER := 0;
    v_current_date TIMESTAMP := CURRENT_TIMESTAMP;
    v_etl_batch_id VARCHAR(100) := 'ETL_BATCH_' || to_char(CURRENT_TIMESTAMP, 'YYYYMMDDHH24MISS');
BEGIN
    -- Start batch
    v_batch_id := log_batch_start('DIM_USERS_LOAD', 'ETL_PROCESS');
    v_start_time := CURRENT_TIMESTAMP;
    
    BEGIN
        -- Expire records that no longer exist in source or have changed
        WITH updated_records AS (
            -- Mark records that need to be expired
            UPDATE dim_users du
            SET 
                expiry_date = v_current_date - INTERVAL '1 second',
                is_current = FALSE,
                etl_timestamp = v_current_date
            FROM (
                SELECT du.user_id
                FROM dim_users du
                LEFT JOIN oltp.users ou ON du.user_id = ou.user_id
                WHERE du.is_current = TRUE
                AND (
                    ou.user_id IS NULL -- Deleted in source
                    OR (
                        -- Changed in source
                        (du.email IS DISTINCT FROM ou.email)
                        OR (du.first_name IS DISTINCT FROM ou.first_name)
                        OR (du.last_name IS DISTINCT FROM ou.last_name)
                        OR (du.role IS DISTINCT FROM ou.role)
                        OR (du.status IS DISTINCT FROM ou.status)
                    )
                )
            ) to_expire
            WHERE du.user_id = to_expire.user_id
            AND du.is_current = TRUE
            RETURNING du.user_key, du.user_id
        )
        SELECT COUNT(*) INTO v_count_expired
        FROM updated_records;
        
        -- Insert new versions of changed records and new records
        WITH new_versions AS (
            -- New versions of changed records
            SELECT 
                ou.*,
                du.user_key as old_user_key
            FROM oltp.users ou
            JOIN dim_users du ON ou.user_id = du.user_id
            WHERE du.is_current = FALSE
            AND du.expiry_date = v_current_date - INTERVAL '1 second'
            
            UNION ALL
            
            -- Brand new records
            SELECT 
                ou.*,
                NULL as old_user_key
            FROM oltp.users ou
            LEFT JOIN dim_users du ON ou.user_id = du.user_id
            WHERE du.user_id IS NULL
        )
        INSERT INTO dim_users (
            user_id,
            username,
            email,
            first_name,
            last_name,
            role,
            status,
            department,
            manager_id,
            hire_date,
            effective_date,
            expiry_date,
            is_current,
            version_number,
            source_system,
            etl_batch_id
        )
        SELECT 
            nv.user_id,
            nv.username,
            nv.email,
            nv.first_name,
            nv.last_name,
            nv.role,
            nv.status,
            nv.department,
            nv.manager_id,
            nv.hire_date,
            v_current_date as effective_date,
            NULL as expiry_date,
            TRUE as is_current,
            CASE 
                WHEN nv.old_user_key IS NOT NULL THEN 
                    (SELECT version_number + 1 FROM dim_users WHERE user_key = nv.old_user_key)
                ELSE 1 
            END as version_number,
            'OLTP' as source_system,
            v_etl_batch_id as etl_batch_id
        FROM new_versions nv
        RETURNING user_key INTO v_count_inserted;
        
        -- Log success
        v_audit_id := log_etl_audit(
            v_batch_id,
            'dim_users',
            'SCD2_LOAD',
            'COMPLETED',
            v_count_inserted + v_count_expired,
            v_start_time,
            CURRENT_TIMESTAMP,
            NULL,
            jsonb_build_object(
                'inserted', v_count_inserted,
                'expired', v_count_expired,
                'unchanged', v_count_unchanged
            )
        );
        
        -- Update batch log
        PERFORM log_batch_end(
            v_batch_id,
            'COMPLETED',
            v_count_inserted + v_count_expired + v_count_unchanged,  -- records_processed
            v_count_inserted,  -- records_inserted
            v_count_expired,   -- records_updated
            0                 -- records_failed
        );
        
    EXCEPTION WHEN OTHERS THEN
        -- Log error
        PERFORM log_etl_error(
            v_batch_id,
            'ERROR',
            SQLSTATE,
            SQLERRM,
            'dim_users',
            NULL,
            jsonb_build_object('error_context', 'Error in load_dim_users')
        );
        
        -- Update audit log
        PERFORM log_etl_audit(
            v_batch_id,
            'dim_users',
            'SCD2_LOAD',
            'FAILED',
            NULL,
            v_start_time,
            CURRENT_TIMESTAMP,
            SQLERRM
        );
        
        -- Update batch log
        PERFORM log_batch_end(
            v_batch_id,
            'FAILED',
            0,  -- records_processed
            0,  -- records_inserted
            0,  -- records_updated
            0,  -- records_failed
            SQLERRM
        );
        
        RAISE;
    END;
END;
$$;

-- Similar procedures for other dimensions (Projects, Task Status, Priority)
-- ...

-- ========== FACT TABLE LOADING ==========

-- Load Fact Tasks
CREATE OR REPLACE PROCEDURE load_fact_tasks()
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch_id VARCHAR(100);
    v_audit_id BIGINT;
    v_start_time TIMESTAMP;
    v_count_inserted INTEGER := 0;
    v_count_updated INTEGER := 0;
    v_count_skipped INTEGER := 0;
    v_count_errors INTEGER := 0;
    v_etl_batch_id VARCHAR(100) := 'ETL_BATCH_' || to_char(CURRENT_TIMESTAMP, 'YYYYMMDDHH24MISS');
BEGIN
    -- Start batch
    v_batch_id := log_batch_start('FACT_TASKS_LOAD', 'ETL_PROCESS');
    v_start_time := CURRENT_TIMESTAMP;
    
    BEGIN
        -- Insert new and update existing tasks
        WITH task_updates AS (
            -- Update existing tasks that have changed
            UPDATE fact_tasks ft
            SET 
                task_sk = ot.task_sk,
                project_key = dp.project_key,
                assigned_to_key = du.user_key,
                reporter_key = dr.user_key,
                status_key = dst.status_key,
                priority_key = dp2.priority_key,
                created_date_key = dt_created.time_key,
                due_date_key = COALESCE(dt_due.time_key, -1),
                completed_date_key = COALESCE(dt_completed.time_key, -1),
                title = ot.title,
                description = ot.description,
                estimated_hours = ot.estimated_hours,
                actual_hours = ot.actual_hours,
                story_points = ot.story_points,
                is_blocked = ot.is_blocked,
                block_reason = ot.block_reason,
                parent_task_id = ot.parent_task_id,
                task_type = ot.task_type,
                labels = ot.labels,
                created_timestamp = ot.created_at,
                updated_timestamp = ot.updated_at,
                days_open = DATE_PART('day', CURRENT_DATE - ot.created_at)::INTEGER,
                days_in_progress = CASE 
                    WHEN ot.status = 'in_progress' THEN 
                        DATE_PART('day', CURRENT_DATE - ot.status_changed_at)::INTEGER 
                    ELSE 0 
                END,
                days_in_review = CASE 
                    WHEN ot.status = 'in_review' THEN 
                        DATE_PART('day', CURRENT_DATE - ot.status_changed_at)::INTEGER 
                    ELSE 0 
                END,
                days_completed = CASE 
                    WHEN ot.status = 'completed' THEN 
                        DATE_PART('day', CURRENT_DATE - ot.completed_at)::INTEGER 
                    ELSE 0 
                END,
                is_overdue = CASE 
                    WHEN ot.due_date IS NOT NULL AND ot.status NOT IN ('completed', 'cancelled') 
                    THEN ot.due_date < CURRENT_DATE 
                    ELSE FALSE 
                END,
                days_overdue = CASE 
                    WHEN ot.due_date IS NOT NULL AND ot.status NOT IN ('completed', 'cancelled') 
                    THEN GREATEST(0, DATE_PART('day', CURRENT_DATE - ot.due_date)::INTEGER)
                    ELSE 0 
                END,
                completion_ratio = CASE 
                    WHEN ot.status = 'completed' THEN 100.0
                    WHEN ot.estimated_hours > 0 AND ot.actual_hours > 0 
                    THEN LEAST(99.9, (ot.actual_hours / ot.estimated_hours) * 100)
                    ELSE 0.0
                END,
                etl_batch_id = v_etl_batch_id,
                etl_timestamp = CURRENT_TIMESTAMP
            FROM oltp.tasks ot
            LEFT JOIN dim_projects dp ON ot.project_id = dp.project_id AND dp.is_current = TRUE
            LEFT JOIN dim_users du ON ot.assigned_to = du.user_id AND du.is_current = TRUE
            LEFT JOIN dim_users dr ON ot.reporter_id = dr.user_id AND dr.is_current = TRUE
            LEFT JOIN dim_task_status dst ON ot.status = dst.status_id AND dst.is_current = TRUE
            LEFT JOIN dim_priority dp2 ON ot.priority = dp2.priority_id AND dp2.is_current = TRUE
            LEFT JOIN dim_time dt_created ON ot.created_at::date = dt_created.full_date
            LEFT JOIN dim_time dt_due ON ot.due_date::date = dt_due.full_date
            LEFT JOIN dim_time dt_completed ON ot.completed_at::date = dt_completed.full_date
            WHERE ft.task_id = ot.task_id
            AND (
                ft.title IS DISTINCT FROM ot.title
                OR ft.description IS DISTINCT FROM ot.description
                OR ft.status_key IS DISTINCT FROM dst.status_key
                OR ft.priority_key IS DISTINCT FROM dp2.priority_key
                OR ft.due_date_key IS DISTINCT FROM COALESCE(dt_due.time_key, -1)
                OR ft.completed_date_key IS DISTINCT FROM COALESCE(dt_completed.time_key, -1)
                -- Add other fields as needed
            )
            RETURNING ft.task_key
        )
        SELECT COUNT(*) INTO v_count_updated
        FROM task_updates;
        
        -- Insert new tasks
        WITH new_tasks AS (
            INSERT INTO fact_tasks (
                task_id,
                task_sk,
                project_key,
                assigned_to_key,
                reporter_key,
                status_key,
                priority_key,
                created_date_key,
                due_date_key,
                completed_date_key,
                title,
                description,
                estimated_hours,
                actual_hours,
                story_points,
                is_blocked,
                block_reason,
                parent_task_id,
                task_type,
                labels,
                created_timestamp,
                updated_timestamp,
                days_open,
                days_in_progress,
                days_in_review,
                days_completed,
                is_overdue,
                days_overdue,
                completion_ratio,
                etl_batch_id
            )
            SELECT 
                ot.task_id,
                ot.task_sk,
                dp.project_key,
                du.user_key as assigned_to_key,
                dr.user_key as reporter_key,
                dst.status_key,
                dp2.priority_key,
                dt_created.time_key as created_date_key,
                COALESCE(dt_due.time_key, -1) as due_date_key,
                COALESCE(dt_completed.time_key, -1) as completed_date_key,
                ot.title,
                ot.description,
                ot.estimated_hours,
                ot.actual_hours,
                ot.story_points,
                ot.is_blocked,
                ot.block_reason,
                ot.parent_task_id,
                ot.task_type,
                ot.labels,
                ot.created_at as created_timestamp,
                ot.updated_at as updated_timestamp,
                DATE_PART('day', CURRENT_DATE - ot.created_at)::INTEGER as days_open,
                CASE 
                    WHEN ot.status = 'in_progress' THEN 
                        DATE_PART('day', CURRENT_DATE - ot.status_changed_at)::INTEGER 
                    ELSE 0 
                END as days_in_progress,
                CASE 
                    WHEN ot.status = 'in_review' THEN 
                        DATE_PART('day', CURRENT_DATE - ot.status_changed_at)::INTEGER 
                    ELSE 0 
                END as days_in_review,
                CASE 
                    WHEN ot.status = 'completed' THEN 
                        DATE_PART('day', CURRENT_DATE - ot.completed_at)::INTEGER 
                    ELSE 0 
                END as days_completed,
                CASE 
                    WHEN ot.due_date IS NOT NULL AND ot.status NOT IN ('completed', 'cancelled') 
                    THEN ot.due_date < CURRENT_DATE 
                    ELSE FALSE 
                END as is_overdue,
                CASE 
                    WHEN ot.due_date IS NOT NULL AND ot.status NOT IN ('completed', 'cancelled') 
                    THEN GREATEST(0, DATE_PART('day', CURRENT_DATE - ot.due_date)::INTEGER)
                    ELSE 0 
                END as days_overdue,
                CASE 
                    WHEN ot.status = 'completed' THEN 100.0
                    WHEN ot.estimated_hours > 0 AND ot.actual_hours > 0 
                    THEN LEAST(99.9, (ot.actual_hours / ot.estimated_hours) * 100)
                    ELSE 0.0
                END as completion_ratio,
                v_etl_batch_id as etl_batch_id
            FROM oltp.tasks ot
            LEFT JOIN dim_projects dp ON ot.project_id = dp.project_id AND dp.is_current = TRUE
            LEFT JOIN dim_users du ON ot.assigned_to = du.user_id AND du.is_current = TRUE
            LEFT JOIN dim_users dr ON ot.reporter_id = dr.user_id AND dr.is_current = TRUE
            LEFT JOIN dim_task_status dst ON ot.status = dst.status_id AND dst.is_current = TRUE
            LEFT JOIN dim_priority dp2 ON ot.priority = dp2.priority_id AND dp2.is_current = TRUE
            LEFT JOIN dim_time dt_created ON ot.created_at::date = dt_created.full_date
            LEFT JOIN dim_time dt_due ON ot.due_date::date = dt_due.full_date
            LEFT JOIN dim_time dt_completed ON ot.completed_at::date = dt_completed.full_date
            LEFT JOIN fact_tasks ft ON ot.task_id = ft.task_id
            WHERE ft.task_id IS NULL
            RETURNING task_key
        )
        SELECT COUNT(*) INTO v_count_inserted
        FROM new_tasks;
        
        -- Log success
        v_audit_id := log_etl_audit(
            v_batch_id,
            'fact_tasks',
            'INCREMENTAL_LOAD',
            'COMPLETED',
            v_count_inserted + v_count_updated,
            v_start_time,
            CURRENT_TIMESTAMP,
            NULL,
            jsonb_build_object(
                'inserted', v_count_inserted,
                'updated', v_count_updated,
                'skipped', v_count_skipped,
                'errors', v_count_errors
            )
        );
        
        -- Update batch log
        PERFORM log_batch_end(
            v_batch_id,
            'COMPLETED',
            v_count_inserted + v_count_updated + v_count_skipped,  -- records_processed
            v_count_inserted,  -- records_inserted
            v_count_updated,   -- records_updated
            v_count_errors     -- records_failed
        );
        
    EXCEPTION WHEN OTHERS THEN
        -- Log error
        PERFORM log_etl_error(
            v_batch_id,
            'ERROR',
            SQLSTATE,
            SQLERRM,
            'fact_tasks',
            NULL,
            jsonb_build_object('error_context', 'Error in load_fact_tasks')
        );
        
        -- Update audit log
        PERFORM log_etl_audit(
            v_batch_id,
            'fact_tasks',
            'INCREMENTAL_LOAD',
            'FAILED',
            NULL,
            v_start_time,
            CURRENT_TIMESTAMP,
            SQLERRM
        );
        
        -- Update batch log
        PERFORM log_batch_end(
            v_batch_id,
            'FAILED',
            0,  -- records_processed
            0,  -- records_inserted
            0,  -- records_updated
            1,  -- records_failed
            SQLERRM
        );
        
        RAISE;
    END;
END;
$$;

-- Load Fact Time Logs
CREATE OR REPLACE PROCEDURE load_fact_time_logs()
LANGUAGE plpgsql
AS $$
-- Similar structure to load_fact_tasks
-- Implementation omitted for brevity
BEGIN
    -- Implementation would follow the same pattern as load_fact_tasks
    -- with appropriate fields for time logging
    NULL;
END;
$$;

-- ========== AGGREGATE LOADING ==========

-- Load Daily Task Metrics
CREATE OR REPLACE PROCEDURE load_agg_daily_task_metrics()
LANGUAGE plpgsql
AS $$
-- Implementation for loading daily task metrics
BEGIN
    -- Implementation would aggregate data from fact_tasks
    -- and load into agg_daily_task_metrics
    NULL;
END;
$$;

-- Load User Workload
CREATE OR REPLACE PROCEDURE load_agg_user_workload()
LANGUAGE plpgsql
AS $$
-- Implementation for loading user workload metrics
BEGIN
    -- Implementation would aggregate data from fact_tasks and fact_time_logs
    -- and load into agg_user_workload
    NULL;
END;
$$;

-- ========== MAIN ETL WORKFLOW ==========

CREATE OR REPLACE PROCEDURE run_etl_workflow()
LANGUAGE plpgsql
AS $$
DECLARE
    v_batch_id VARCHAR(100);
    v_start_time TIMESTAMP;
    v_error_message TEXT;
BEGIN
    -- Start main ETL batch
    v_batch_id := log_batch_start('FULL_ETL_WORKFLOW', 'ETL_MASTER');
    v_start_time := CURRENT_TIMESTAMP;
    
    BEGIN
        -- 1. Load dimensions (with SCD Type 2 handling)
        CALL load_dim_users();
        CALL load_dim_projects();  -- Implementation not shown
        CALL load_dim_task_status();  -- Implementation not shown
        CALL load_dim_priority();  -- Implementation not shown
        
        -- 2. Load fact tables
        CALL load_fact_tasks();
        CALL load_fact_time_logs();
        
        -- 3. Load aggregate tables
        CALL load_agg_daily_task_metrics();
        CALL load_agg_user_workload();
        
        -- Log success
        PERFORM log_batch_end(
            v_batch_id,
            'COMPLETED',
            NULL,  -- Records processed will be summed from individual steps
            NULL,  -- Records inserted will be summed from individual steps
            NULL,  -- Records updated will be summed from individual steps
            0,     -- No errors if we got here
            'ETL workflow completed successfully'
        );
        
    EXCEPTION WHEN OTHERS THEN
        -- Log error
        v_error_message := SQLERRM;
        
        PERFORM log_etl_error(
            v_batch_id,
            'CRITICAL',
            SQLSTATE,
            v_error_message,
            'ETL_WORKFLOW',
            NULL,
            jsonb_build_object('error_context', 'Error in ETL workflow')
        );
        
        -- Update batch log
        PERFORM log_batch_end(
            v_batch_id,
            'FAILED',
            NULL,
            NULL,
            NULL,
            1,  -- At least one error occurred
            v_error_message
        );
        
        -- Re-raise the exception to ensure the caller knows something went wrong
        RAISE EXCEPTION 'ETL workflow failed: %', v_error_message;
    END;
END;
$$;

-- ========== SCHEDULED JOBS ==========

-- Create a function to be called by pg_cron for scheduled ETL
CREATE OR REPLACE FUNCTION schedule_etl_workflow()
RETURNS VOID AS $$
BEGIN
    CALL run_etl_workflow();
EXCEPTION WHEN OTHERS THEN
    -- Log the error but don't fail the function
    RAISE WARNING 'Scheduled ETL workflow failed: %', SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- Schedule the ETL job to run daily at 1 AM
-- Note: This requires pg_cron extension to be installed and configured
-- SELECT cron.schedule('0 1 * * *', 'SELECT schedule_etl_workflow()');

-- ========== UTILITY FUNCTIONS ==========

-- Function to get the latest ETL batch ID
CREATE OR REPLACE FUNCTION get_latest_etl_batch()
RETURNS TABLE (
    batch_id VARCHAR(100),
    batch_start_time TIMESTAMP,
    batch_end_time TIMESTAMP,
    status VARCHAR(20),
    duration_seconds DECIMAL(10, 2),
    records_processed INTEGER,
    records_inserted INTEGER,
    records_updated INTEGER,
    records_failed INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ebl.batch_id,
        ebl.batch_start_time,
        ebl.batch_end_time,
        ebl.status,
        EXTRACT(EPOCH FROM (ebl.batch_end_time - ebl.batch_start_time))::DECIMAL(10, 2) as duration_seconds,
        ebl.records_processed,
        ebl.records_inserted,
        ebl.records_updated,
        ebl.records_failed
    FROM etl_batch_log ebl
    ORDER BY ebl.batch_start_time DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql;

-- Function to check ETL status
CREATE OR REPLACE FUNCTION check_etl_status(
    p_hours_back INTEGER DEFAULT 24
)
RETURNS TABLE (
    batch_id VARCHAR(100),
    batch_start_time TIMESTAMP,
    batch_end_time TIMESTAMP,
    status VARCHAR(20),
    duration_minutes DECIMAL(10, 2),
    records_processed INTEGER,
    error_message TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ebl.batch_id,
        ebl.batch_start_time,
        ebl.batch_end_time,
        ebl.status,
        EXTRACT(EPOCH FROM (ebl.batch_end_time - ebl.batch_start_time)) / 60.0 as duration_minutes,
        ebl.records_processed,
        ebl.error_message
    FROM etl_batch_log ebl
    WHERE ebl.batch_start_time >= (CURRENT_TIMESTAMP - (p_hours_back || ' hours')::INTERVAL)
    ORDER BY ebl.batch_start_time DESC;
END;
$$ LANGUAGE plpgsql;
