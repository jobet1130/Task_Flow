# Task Management System - Monitoring & Optimization Guide

## Table of Contents
1. [Setup & Configuration](#setup--configuration)
2. [Performance Monitoring](#performance-monitoring)
3. [Query Analysis](#query-analysis)
4. [Index Optimization](#index-optimization)
5. [Table Maintenance](#table-maintenance)
6. [Connection Management](#connection-management)
7. [Deadlock Detection](#deadlock-detection)
8. [Dashboard Setup](#dashboard-setup)
9. [Alerting](#alerting)
10. [Maintenance Tasks](#maintenance-tasks)

## Setup & Configuration

### 1. Enable Required Extensions
```sql
-- Install essential extensions
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_buffercache;
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
CREATE EXTENSION IF NOT EXISTS pg_visibility;
```

### 2. Configure postgresql.conf
```ini
# Monitoring
shared_preload_libraries = 'pg_stat_statements,auto_explain'
track_io_timing = on
track_activity_query_size = 2048
log_min_duration_statement = 1000  # Log queries slower than 1s
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0

# pg_stat_statements configuration
pg_stat_statements.track = all
pg_stat_statements.max = 10000
track_io_timing = on
```

## Performance Monitoring

### 1. System Resource Usage
```sql
-- CPU and memory usage by database
SELECT 
    datname,
    numbackends,
    xact_commit + xact_rollback as total_transactions,
    tup_inserted + tup_updated + tup_deleted as total_changes,
    blks_read,
    blks_hit,
    round(100 * blks_hit::numeric / nullif(blks_hit + blks_read, 0), 2) as hit_ratio
FROM pg_stat_database 
WHERE datname NOT IN ('template0', 'template1', 'postgres');
```

### 2. Table Statistics
```sql
-- Table statistics
SELECT 
    schemaname,
    relname,
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    n_tup_ins,
    n_tup_upd,
    n_tup_del,
    n_live_tup,
    n_dead_tup,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC;
```

## Query Analysis

### 1. Slow Queries
```sql
-- Top 10 slowest queries (requires pg_stat_statements)
SELECT 
    query,
    calls,
    total_exec_time,
    mean_exec_time,
    rows,
    100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0) as hit_percent
FROM pg_stat_statements 
JOIN pg_database ON pg_database.oid = dbid
WHERE query NOT LIKE '%pg_%'
ORDER BY mean_exec_time DESC 
LIMIT 10;
```

### 2. Query Execution Plans
```sql
-- Explain analyze for a specific query
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
SELECT * FROM tasks WHERE status = 'open' AND due_date < NOW();

-- Enable auto_explain for all queries > 1s
ALTER SYSTEM SET auto_explain.log_min_duration = '1s';
ALTER SYSTEM SET auto_explain.log_analyze = on;
ALTER SYSTEM SET auto_explain.log_buffers = on;
ALTER SYSTEM SET auto_explain.log_timing = on;
ALTER SYSTEM SET auto_explain.log_verbose = on;
```

## Index Optimization

### 1. Index Usage Statistics
```sql
-- Index usage statistics
SELECT 
    schemaname,
    relname,
    indexrelname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
JOIN pg_statio_user_indexes USING (indexrelid)
ORDER BY pg_relation_size(indexrelid) DESC;
```

### 2. Missing Indexes
```sql
-- Potentially missing indexes
SELECT 
    relname AS table_name,
    seq_scan - COALESCE(idx_scan, 0) AS seq_scans,
    seq_scan as sequential_scans,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    idx_scan as index_scans,
    n_live_tup as rows_in_table
FROM pg_stat_user_tables
WHERE seq_scan > 0
ORDER BY seq_scan - COALESCE(idx_scan, 0) DESC;
```

### 3. Duplicate Indexes
```sql
-- Find duplicate indexes
SELECT
    indrelid::regclass as table_name,
    array_agg(indexrelid::regclass) as indexes,
    pg_size_pretty(sum(pg_relation_size(indexrelid::regclass))) as total_size
FROM pg_index
JOIN pg_stat_all_indexes USING (indexrelid)
WHERE schemaname = 'public'
GROUP BY indrelid, indkey
HAVING count(*) > 1;
```

## Table Maintenance

### 1. Table Bloat Analysis
```sql
-- Table bloat analysis
SELECT
    nspname as schema_name,
    tblname as table_name,
    pg_size_pretty(pg_total_relation_size(quote_ident(nspname) || '.' || quote_ident(tblname))) as total_size,
    pg_size_pretty(pg_relation_size(quote_ident(nspname) || '.' || quote_ident(tblname))) as table_size,
    pg_size_pretty(pg_total_relation_size(quote_ident(nspname) || '.' || quote_ident(tblname)) - 
                  pg_relation_size(quote_ident(nspname) || '.' || quote_ident(tblname))) as index_size,
    pg_stat_get_live_tuples(quote_ident(nspname) || '.' || quote_ident(tblname)::regclass) as live_tuples,
    pg_stat_get_dead_tuples(quote_ident(nspname) || '.' || quote_ident(tblname)::regclass) as dead_tuples
FROM (
    SELECT
        n.nspname,
        c.relname as tblname,
        c.reltuples
    FROM pg_namespace n
    JOIN pg_class c ON n.oid = c.relnamespace
    WHERE c.relkind = 'r'
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
) t
ORDER BY pg_total_relation_size(quote_ident(nspname) || '.' || quote_ident(tblname)) DESC;
```

### 2. Vacuum Analysis
```sql
-- Tables that need vacuuming
SELECT
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    last_autovacuum,
    last_autoanalyze,
    n_dead_tup > av_threshold AS needs_vacuum,
    CASE
        WHEN reltuples > 0
        THEN round(100.0 * n_dead_tup / (n_live_tup + n_dead_tup), 2)
        ELSE 0
    END AS dead_tup_ratio
FROM (
    SELECT
        schemaname,
        relname,
        n_live_tup,
        n_dead_tup,
        last_autovacuum,
        last_autoanalyze,
        reltuples,
        current_setting('autovacuum_vacuum_threshold')::integer + (
            current_setting('autovacuum_vacuum_scale_factor')::numeric * reltuples
        ) AS av_threshold
    FROM pg_stat_user_tables
    JOIN pg_class ON pg_stat_user_tables.relid = pg_class.oid
) AS av
WHERE n_dead_tup > av_threshold
ORDER BY dead_tup_ratio DESC;
```

## Connection Management

### 1. Active Connections
```sql
-- Active connections by database and user
SELECT 
    datname,
    usename,
    application_name,
    client_addr,
    state,
    count(*) as connection_count
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
GROUP BY datname, usename, application_name, client_addr, state
ORDER BY connection_count DESC;
```

### 2. Long-Running Queries
```sql
-- Long-running queries
SELECT
    pid,
    now() - query_start as duration,
    datname,
    usename,
    application_name,
    state,
    query
FROM pg_stat_activity
WHERE state != 'idle'
AND now() - query_start > interval '5 minutes'
ORDER BY duration DESC;
```

### 3. Connection Pooling
```ini
# Example pgBouncer configuration (pgbouncer.ini)
[databases]
task_management = host=localhost dbname=task_management

[pgbouncer]
listen_port = 6432
listen_addr = *
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
admin_users = postgres
pool_mode = transaction
max_client_conn = 500
default_pool_size = 100
reserve_pool_size = 20
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
```

## Deadlock Detection

### 1. Current Locks
```sql
-- Current locks and blocking queries
SELECT
    blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocked_activity.query AS blocked_statement,
    blocking_activity.query AS current_statement_in_blocking_process
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks blocking_locks 
    ON blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.DATABASE IS NOT DISTINCT FROM blocked_locks.DATABASE
    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
    AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
    AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
    AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
    AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
    AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
    AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
    AND blocking_locks.objsubid = blocked_locks.objsubid
    AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.GRANTED;
```

### 2. Deadlock Logging
```ini
# In postgresql.conf
log_lock_waits = on
deadlock_timeout = 1s
log_min_duration_statement = 0
log_statement = 'none'
log_duration = off
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0
```

## Dashboard Setup

### 1. Grafana Dashboard Queries
```sql
-- CPU Usage
SELECT
    now() as time,
    usename,
    application_name,
    (total_time / 1000 / 60) as total_minutes,
    calls,
    (total_time / calls) as avg_time_ms,
    query
FROM pg_stat_statements
JOIN pg_database ON pg_database.oid = dbid
JOIN pg_user ON pg_user.usesysid = userid
WHERE query NOT LIKE '%pg_%'
ORDER BY total_time DESC
LIMIT 10;

-- Memory Usage
SELECT
    c.relname,
    pg_size_pretty(count(*) * 8192) as buffered,
    round(100.0 * count(*) / (
        SELECT setting FROM pg_settings WHERE name='shared_buffers'
    )::integer, 1) as buffer_percent,
    round(100.0 * count(*) * 8192 / pg_table_size(c.oid), 1) as percent_of_relation
FROM pg_class c
INNER JOIN pg_buffercache b ON b.relfilenode = c.relfilenode
INNER JOIN pg_database d ON (b.reldatabase = d.oid AND d.datname = current_database())
GROUP BY c.oid, c.relname
ORDER BY count(*) DESC
LIMIT 25;
```

### 2. Prometheus Metrics
```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'postgres'
    static_configs:
      - targets: ['localhost:9187']
    metrics_path: /metrics
    params:
      collect[]:
        - custom_query.pg_stat_database
        - custom_query.pg_stat_user_tables
        - custom_query.pg_stat_statements
        - custom_query.pg_stat_activity
```

## Alerting

### 1. Critical Alerts
```sql
-- Long-running transactions
SELECT
    pid,
    now() - xact_start as duration,
    query,
    state
FROM pg_stat_activity
WHERE now() - xact_start > interval '10 minutes';

-- Replication lag
SELECT
    now() - pg_last_xact_replay_timestamp() AS replication_delay;

-- Connection count
SELECT count(*) 
FROM pg_stat_activity 
WHERE state = 'active';
```

### 2. Alert Manager Configuration
```yaml
# alertmanager.yml
route:
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 3h
  receiver: 'slack'

receivers:
- name: 'slack'
  slack_configs:
  - api_url: 'https://hooks.slack.com/services/...'
    channel: '#database-alerts'
    send_resolved: true
    title: '{{ .CommonAnnotations.summary }}'
    text: '{{ .CommonAnnotations.description }}'
```

## Maintenance Tasks

### 1. Weekly Maintenance
```sql
-- Update statistics
ANALYZE VERBOSE;

-- Rebuild indexes on heavily updated tables
REINDEX TABLE tasks, users, projects;

-- Vacuum and analyze specific tables
VACUUM (VERBOSE, ANALYZE) tasks;
```

### 2. Monthly Maintenance
```sql
-- Check for unused indexes
SELECT
    schemaname,
    relname,
    indexrelname,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
JOIN pg_statio_user_indexes USING (indexrelid)
WHERE idx_scan < 50  -- Fewer than 50 scans
ORDER BY pg_relation_size(indexrelid) DESC;

-- Check for table bloat
VACUUM (VERBOSE, ANALYZE);
```

## Performance Tuning Recommendations

1. **Connection Pooling**: Use PgBouncer or pgpool-II for connection pooling
2. **Work Memory**: Adjust `work_mem` based on your workload
3. **Shared Buffers**: Set to 25% of total RAM
4. **Maintenance Work Memory**: Increase for large databases
5. **Checkpoint Segments**: Adjust based on write volume
6. **Autovacuum**: Tune autovacuum parameters for your workload
7. **Partitioning**: Consider for large tables with time-series data
8. **Query Optimization**: Use EXPLAIN ANALYZE to optimize slow queries
9. **Indexing**: Create appropriate indexes and remove unused ones
10. **Monitoring**: Set up comprehensive monitoring and alerting
