-- =====================================================================
-- Seed / Sample Data for dr_automation_db
-- Run AFTER schema.sql
-- =====================================================================
USE dr_automation_db;

-- DR SITES
INSERT INTO dr_sites (site_name, site_type, provider, region) VALUES
('AWS us-west-2 DR',        'Warm', 'AWS',   'us-west-2'),
('AWS us-east-1 Primary',   'Hot',  'AWS',   'us-east-1'),
('Azure West Europe DR',    'Cold', 'Azure', 'westeurope'),
('On-Prem Secondary DC',    'Cold', 'On-Prem','Pune-DC2');

-- SYSTEMS
INSERT INTO systems (system_name, description, environment, criticality_tier, owner_team, rto_target_minutes, rpo_target_minutes, primary_region, dr_site_id) VALUES
('Payment Gateway API',     'Handles all customer payment transactions', 'Production', 'Tier1', 'Payments Eng', 15, 5, 'us-east-1', 1),
('Customer Portal Web App', 'Public-facing customer self-service portal', 'Production', 'Tier1', 'Web Platform', 30, 15, 'us-east-1', 1),
('Internal HR System',      'Employee management system', 'Production', 'Tier2', 'IT Ops', 240, 60, 'westeurope', 3),
('Analytics Data Warehouse','Reporting and BI data warehouse', 'Production', 'Tier2', 'Data Eng', 480, 120, 'us-east-1', 1),
('Legacy Inventory System', 'On-prem legacy inventory tracking', 'Production', 'Tier3', 'Ops', 1440, 720, 'Pune-DC1', 4);

-- DR PLANS
INSERT INTO dr_plans (system_id, strategy, runbook_url, last_reviewed, reviewed_by, version) VALUES
(1, 'Active-Active',  'https://github.com/org/dr-runbooks/payment-gateway.md', '2026-06-15', 'A. Sharma', '3.2'),
(2, 'Warm-Standby',   'https://github.com/org/dr-runbooks/customer-portal.md', '2026-05-20', 'A. Sharma', '2.1'),
(3, 'Pilot-Light',    'https://github.com/org/dr-runbooks/hr-system.md',       '2026-03-10', 'R. Iyer',   '1.4'),
(4, 'Backup-Restore', 'https://github.com/org/dr-runbooks/data-warehouse.md',  '2026-04-01', 'R. Iyer',   '1.0'),
(5, 'Backup-Restore', 'https://github.com/org/dr-runbooks/legacy-inventory.md','2026-01-25', 'S. Patel',  '1.0');

-- BACKUPS
INSERT INTO backups (system_id, backup_type, start_time, end_time, status, size_gb, storage_location, verified, verified_at) VALUES
(1, 'Incremental', '2026-08-21 02:00:00', '2026-08-21 02:04:00', 'Success', 12.5,  's3://dr-backups/payment-gw/2026-08-21', TRUE,  '2026-08-21 04:00:00'),
(1, 'Full',        '2026-08-14 02:00:00', '2026-08-14 02:45:00', 'Success', 210.0, 's3://dr-backups/payment-gw/2026-08-14', TRUE,  '2026-08-14 06:00:00'),
(2, 'Snapshot',    '2026-08-21 03:00:00', '2026-08-21 03:10:00', 'Success', 45.2,  's3://dr-backups/portal/2026-08-21',     FALSE, NULL),
(3, 'Full',        '2026-08-20 01:00:00', '2026-08-20 01:30:00', 'Success', 30.0,  'azureblob://dr-backups/hr/2026-08-20',  TRUE,  '2026-08-20 05:00:00'),
(4, 'Full',        '2026-08-18 00:00:00', '2026-08-18 03:20:00', 'Failed',  NULL,  's3://dr-backups/dwh/2026-08-18',        FALSE, NULL),
(5, 'Full',        '2026-08-01 22:00:00', '2026-08-02 01:00:00', 'Success', 500.0, 'nfs://dc2/backups/inventory/2026-08-01',TRUE,  '2026-08-05 10:00:00');

-- DR TESTS
INSERT INTO dr_tests (system_id, test_date, test_type, rto_achieved_minutes, rpo_achieved_minutes, result, conducted_by, notes) VALUES
(1, '2026-07-10', 'Full-Interruption', 14, 4,  'Pass',    'A. Sharma', 'Automated failover script executed cleanly, no manual steps needed.'),
(2, '2026-06-15', 'Simulation',        35, 18, 'Partial', 'A. Sharma', 'RTO slightly missed target due to DNS TTL propagation delay.'),
(3, '2026-05-01', 'Tabletop',          NULL, NULL, 'Pass', 'R. Iyer',   'Walkthrough only, no live failover performed.'),
(4, '2026-04-15', 'Parallel',          510, 130, 'Fail',   'R. Iyer',   'Backup restore took longer than expected; investigating storage throughput.'),
(5, '2026-02-01', 'Walkthrough',       NULL, NULL, 'Pass',  'S. Patel',  'Manual runbook reviewed and validated with ops team.');

-- INCIDENTS
INSERT INTO incidents (system_id, severity, start_time, resolved_time, dr_invoked, description, root_cause, resolution) VALUES
(1, 'SEV1', '2026-07-02 09:15:00', '2026-07-02 09:32:00', TRUE,
   'Primary region payment API unreachable', 'AWS us-east-1 AZ network outage',
   'Automated failover to us-west-2 warm standby via Route 53 health check + Terraform-provisioned scale-up'),
(4, 'SEV3', '2026-04-15 22:00:00', '2026-04-16 06:30:00', FALSE,
   'Nightly ETL and backup job failed repeatedly', 'Storage volume throughput throttling',
   'Increased provisioned IOPS on backup volume; added retry logic to ETL job');

-- AUTOMATION SCRIPTS
INSERT INTO automation_scripts (script_name, purpose, language, repo_path, system_id, is_active) VALUES
('failover_payment_gw.sh',       'Failover',       'Bash',       'scripts/failover/failover_payment_gw.sh',       1, TRUE),
('backup_verify.py',             'Restore-Test',   'Python',     'scripts/backup/backup_verify.py',               1, TRUE),
('provision_dr_env.tf',          'Provisioning',   'Terraform',  'infra/dr/provision_dr_env.tf',                  2, TRUE),
('health_check_alert.py',        'Monitoring',     'Python',     'scripts/monitoring/health_check_alert.py',      NULL, TRUE),
('nightly_backup_hr.yml',        'Backup',         'Ansible',    'playbooks/nightly_backup_hr.yml',               3, TRUE);

-- AUTOMATION RUNS
INSERT INTO automation_runs (script_id, run_time, status, duration_seconds, triggered_by, log_summary) VALUES
(1, '2026-07-02 09:16:00', 'Success', 45,  'Alert-Triggered', 'Failover completed, traffic shifted to us-west-2'),
(2, '2026-08-21 04:00:00', 'Success', 320, 'Scheduled',       'Restore test passed, checksum verified'),
(3, '2026-08-15 10:00:00', 'Success', 610, 'Manual',          'DR environment provisioned successfully for quarterly test'),
(4, '2026-08-21 00:05:00', 'Success', 5,   'Scheduled',       'All systems healthy'),
(5, '2026-08-20 01:00:00', 'Success', 1800,'Scheduled',       'HR system full backup completed');
