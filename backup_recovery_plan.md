# Task Management System - Backup & Recovery Plan

## Table of Contents
1. [Backup Strategy](#backup-strategy)
2. [Recovery Procedures](#recovery-procedures)
3. [High Availability Setup](#high-availability-setup)
4. [Automation & Monitoring](#automation--monitoring)
5. [Testing & Validation](#testing--validation)

## Backup Strategy

### 1. Full Backups
```bash
# Create base backup directory
sudo mkdir -p /backups/postgresql/
sudo chown postgres:postgres /backups/postgresql/

# Take a full base backup
pg_basebackup -D /backups/postgresql/full_backup_$(date +%Y%m%d) -Ft -z -P -U postgres

# With WAL archiving
pg_basebackup -D /backups/postgresql/full_backup_$(date +%Y%m%d) -Ft -z -P -U postgres --wal-method=stream
```

### 2. Continuous WAL Archiving
```sql
-- In postgresql.conf
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /backups/postgresql/wal_archive/%f && cp %p /backups/postgresql/wal_archive/%f'
archive_timeout = 1h
```

### 3. Incremental Backups
```bash
# Take a WAL backup (incremental)
pg_archivecleanup /backups/postgresql/wal_archive/ 000000010000000000000001

# Or using pg_basebackup for incremental
pg_basebackup -D /backups/postgresql/incr_backup_$(date +%Y%m%d_%H%M%S) \
  -Fp -P -R --checkpoint=fast --wal-method=fetch -U postgres
```

## Recovery Procedures

### 1. Point-in-Time Recovery (PITR)
```bash
# Create recovery.conf (PostgreSQL 12 and earlier) or use postgresql.auto.conf
cat > /var/lib/postgresql/data/recovery.conf << EOF
restore_command = 'cp /backups/postgresql/wal_archive/%f "%p"'
recovery_target_time = '2025-09-10 15:00:00+08:00'
recovery_target_action = 'promote'
EOF

# For PostgreSQL 13+
cat >> /var/lib/postgresql/data/postgresql.auto.conf << EOF
restore_command = 'cp /backups/postgresql/wal_archive/%f "%p"'
recovery_target_time = '2025-09-10 15:00:00+08:00'
recovery_target_action = 'promote'
EOF

# Create recovery.signal file
touch /var/lib/postgresql/data/recovery.signal
```

### 2. Full Database Restore
```bash
# Stop PostgreSQL
sudo systemctl stop postgresql

# Remove existing data directory
sudo -u postgres rm -rf /var/lib/postgresql/data/*

# Restore from base backup
sudo -u postgres tar -xzf /backups/postgresql/full_backup_20230910/base.tar.gz -C /var/lib/postgresql/data/

# Configure recovery
cat > /var/lib/postgresql/data/recovery.conf << EOF
restore_command = 'cp /backups/postgresql/wal_archive/%f "%p"'
recovery_target_timeline = 'latest'
EOF

# Start PostgreSQL
sudo systemctl start postgresql
```

## High Availability Setup

### 1. Streaming Replication (Primary-Standby)
```sql
-- On primary server (postgresql.conf)
wal_level = replica
max_wal_senders = 3
wal_keep_size = 1GB
hot_standby = on

-- Create replication user
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'secure_password';

-- In pg_hba.conf on primary
host    replication     replicator      standby_ip/32       scram-sha-256

-- On standby server (recovery.conf for PostgreSQL 12-)
primary_conninfo = 'host=primary_ip port=5432 user=replicator password=secure_password'
standby_mode = 'on'

-- For PostgreSQL 13+
primary_conninfo = 'host=primary_ip port=5432 user=replicator password=secure_password'
```

### 2. Automatic Failover with Patroni
```yaml
# /etc/patroni/config.yml
scope: task_management
namespace: /service/
name: node1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 192.168.1.101:8008

etcd:
  hosts: ["etcd1:2379", "etcd2:2379", "etcd3:2379"]

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        wal_keep_size: 1GB
        max_wal_senders: 10
        max_replication_slots: 10
        max_connections: "100"

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 192.168.1.101:5432
  data_dir: /var/lib/postgresql/data/pgdata
  bin_dir: /usr/lib/postgresql/14/bin/
  pgpass: /tmp/pgpass
  authentication:
    replication:
      username: replicator
      password: secure_password
    superuser:
      username: postgres
      password: secure_password
  create_replica_methods:
    - basebackup
  basebackup:
    max-rate: '100M'
    checkpoint: 'fast'
```

## Automation & Monitoring

### 1. Backup Script
```bash
#!/bin/bash
# /usr/local/bin/pg_backup.sh

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/postgresql"
WAL_ARCHIVE="$BACKUP_DIR/wal_archive"
FULL_BACKUP_DIR="$BACKUP_DIR/full_$DATE"
LOG_FILE="/var/log/postgresql/backup_$DATE.log"

# Create directories if they don't exist
mkdir -p "$FULL_BACKUP_DIR" "$WAL_ARCHIVE"

# Take base backup
pg_basebackup -D "$FULL_BACKUP_DIR" -Ft -z -P -U postgres --wal-method=stream 2>> "$LOG_FILE"

# Cleanup old backups (keep last 7 days)
find "$BACKUP_DIR" -type d -name "full_*" -mtime +7 -exec rm -rf {} +
find "$WAL_ARCHIVE" -type f -mtime +14 -delete

# Log completion
echo "Backup completed at $(date)" >> "$LOG_FILE"
```

### 2. Cron Job for Regular Backups
```bash
# Daily full backup at 2 AM
0 2 * * * postgres /usr/local/bin/pg_backup.sh

# WAL archiving every 5 minutes
*/5 * * * * postgres pg_archivecleanup /backups/postgresql/wal_archive/ 000000010000000000000001
```

### 3. Monitoring with pgMonitor
```bash
# Install pgMonitor
git clone https://github.com/CrunchyData/pgmonitor.git
cd pgmonitor/postgres_exporter/linux
./setup.sh

# Configure Prometheus to scrape metrics
# Add to prometheus.yml:
scrape_configs:
  - job_name: 'postgres'
    static_configs:
      - targets: ['postgres-server:9187']
```

## Testing & Validation

### 1. Test Recovery Procedure
```bash
# Create test database and table
psql -U postgres -c "CREATE DATABASE recovery_test;"
psql -U postgres -d recovery_test -c "CREATE TABLE test_data (id SERIAL, data TEXT);"

# Insert test data
psql -U postgres -d recovery_test -c "INSERT INTO test_data (data) VALUES ('before backup');"

# Take backup
pg_basebackup -D /backups/postgresql/test_recovery -Ft -z -P -U postgres

# Insert more data
psql -U postgres -d recovery_test -c "INSERT INTO test_data (data) VALUES ('after backup');"

# Simulate disaster
sudo systemctl stop postgresql
sudo rm -rf /var/lib/postgresql/data/*

# Restore from backup and recover
sudo -u postgres tar -xzf /backups/postgresql/test_recovery/base.tar.gz -C /var/lib/postgresql/data/
sudo systemctl start postgresql

# Verify data
psql -U postgres -d recovery_test -c "SELECT * FROM test_data;"
```

### 2. Failover Testing
```bash
# On primary
sudo systemctl stop postgresql

# On standby
SELECT pg_promote();

# Verify new primary is writable
psql -U postgres -c "CREATE DATABASE failover_test;"
```

## Maintenance Tasks

### 1. Regular Maintenance
```sql
-- Update statistics
ANALYZE VERBOSE;

-- Rebuild indexes
REINDEX DATABASE task_management;

-- Vacuum and analyze
VACUUM (VERBOSE, ANALYZE);
```

### 2. Monitoring Queries
```sql
-- Check replication status
SELECT * FROM pg_stat_replication;

-- Check WAL archiving status
SELECT * FROM pg_stat_archiver;

-- Check backup status
SELECT * FROM pg_stat_progress_basebackup;

-- Check locks
SELECT * FROM pg_locks;
```

## Disaster Recovery Plan

### 1. Complete Server Failure
1. Launch new server with same IP/DNS
2. Restore latest base backup
3. Apply WAL archives
4. Update connection strings if IP changed

### 2. Data Corruption
1. Identify corrupted tables
2. Restore from backup if possible
3. Use pg_repair if indexes are corrupted
4. Consider logical replication for minimal downtime

### 3. Accidental Deletion
1. Stop writes to the database
2. Use PITR to recover to just before deletion
3. Export and restore only the missing data
4. Resume normal operations

## Backup Retention Policy

| Backup Type | Retention Period | Location |
|-------------|------------------|----------|
| Full Backups | 30 days | Local disk + Offsite |
| WAL Archives | 14 days | Local disk |
| Base Backups | 7 days | Local disk |
| Transaction Logs | 48 hours | Local disk |

## Performance Considerations

1. **Backup Window**: Schedule backups during low-traffic periods
2. **Network Bandwidth**: Consider network impact when transferring backups
3. **Storage**: Ensure sufficient disk space for WAL archives
4. **Monitoring**: Monitor backup completion and success rates

## Security Considerations

1. **Encryption**: Encrypt backups at rest and in transit
2. **Access Control**: Restrict backup file permissions
3. **Audit Logging**: Log all backup and restore operations
4. **Key Management**: Securely store encryption keys

## Documentation & Training

1. Document recovery procedures
2. Train staff on backup/restore processes
3. Maintain contact information for database administrators
4. Regularly review and update this plan

## Review & Testing Schedule

| Task | Frequency | Owner |
|------|-----------|-------|
| Test backup restoration | Monthly | DBA |
| Verify backup integrity | Weekly | DBA |
| Update recovery procedures | Quarterly | DBA |
| Review backup retention policy | Bi-annually | IT Manager |

## Emergency Contacts

| Role | Name | Contact |
|------|------|---------|
| Primary DBA | [Name] | [Phone] |
| Secondary DBA | [Name] | [Phone] |
| IT Manager | [Name] | [Phone] |
| Cloud Provider Support | - | [Contact] |

## Post-Recovery Steps

1. Verify data consistency
2. Update monitoring systems
3. Document the incident and recovery process
4. Review and update procedures if needed
5. Conduct post-mortem analysis for major incidents
