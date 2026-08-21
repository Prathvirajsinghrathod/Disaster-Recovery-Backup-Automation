-- =====================================================================
-- Disaster Recovery & Automation Tracker — MySQL Schema
-- =====================================================================
-- Purpose: Tracks business systems, their DR posture (RTO/RPO targets),
-- backup jobs, DR test drills, incidents, and automation scripts/runs.
-- Compatible with MySQL 8.0+
-- =====================================================================

DROP DATABASE IF EXISTS dr_automation_db;
CREATE DATABASE dr_automation_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE dr_automation_db;

-- ---------------------------------------------------------------------
-- 1. DR SITES — physical/cloud locations that can host recovery infra
-- ---------------------------------------------------------------------
CREATE TABLE dr_sites (
    site_id         INT AUTO_INCREMENT PRIMARY KEY,
    site_name       VARCHAR(100) NOT NULL,
    site_type       ENUM('Hot', 'Warm', 'Cold') NOT NULL,
    provider        VARCHAR(50)  NOT NULL,          -- AWS, Azure, GCP, On-Prem
    region          VARCHAR(50)  NOT NULL,
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- ---------------------------------------------------------------------
-- 2. SYSTEMS — business applications/services under DR management
-- ---------------------------------------------------------------------
CREATE TABLE systems (
    system_id       INT AUTO_INCREMENT PRIMARY KEY,
    system_name     VARCHAR(100) NOT NULL,
    description     VARCHAR(255),
    environment     ENUM('Production', 'Staging', 'Development') DEFAULT 'Production',
    criticality_tier ENUM('Tier1', 'Tier2', 'Tier3') NOT NULL,   -- Tier1 = most critical
    owner_team      VARCHAR(100),
    rto_target_minutes INT NOT NULL,                -- Recovery Time Objective
    rpo_target_minutes INT NOT NULL,                -- Recovery Point Objective
    primary_region  VARCHAR(50),
    dr_site_id      INT,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (dr_site_id) REFERENCES dr_sites(site_id)
        ON DELETE SET NULL
);

-- ---------------------------------------------------------------------
-- 3. DR PLANS — the documented recovery strategy per system
-- ---------------------------------------------------------------------
CREATE TABLE dr_plans (
    plan_id         INT AUTO_INCREMENT PRIMARY KEY,
    system_id       INT NOT NULL,
    strategy        ENUM('Backup-Restore','Pilot-Light','Warm-Standby','Active-Active') NOT NULL,
    runbook_url     VARCHAR(255),
    last_reviewed   DATE,
    reviewed_by     VARCHAR(100),
    version         VARCHAR(20) DEFAULT '1.0',
    FOREIGN KEY (system_id) REFERENCES systems(system_id)
        ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 4. BACKUPS — backup job history
-- ---------------------------------------------------------------------
CREATE TABLE backups (
    backup_id       BIGINT AUTO_INCREMENT PRIMARY KEY,
    system_id       INT NOT NULL,
    backup_type     ENUM('Full','Incremental','Snapshot','Log') NOT NULL,
    start_time      DATETIME NOT NULL,
    end_time        DATETIME,
    status          ENUM('Success','Failed','Running','Skipped') NOT NULL,
    size_gb         DECIMAL(10,2),
    storage_location VARCHAR(255),         -- e.g., s3://bucket/path
    verified        BOOLEAN DEFAULT FALSE, -- was restore-tested?
    verified_at     DATETIME,
    FOREIGN KEY (system_id) REFERENCES systems(system_id)
        ON DELETE CASCADE,
    INDEX idx_backups_system_time (system_id, start_time)
);

-- ---------------------------------------------------------------------
-- 5. DR TESTS — drills/failover exercises
-- ---------------------------------------------------------------------
CREATE TABLE dr_tests (
    test_id         INT AUTO_INCREMENT PRIMARY KEY,
    system_id       INT NOT NULL,
    test_date       DATE NOT NULL,
    test_type       ENUM('Tabletop','Walkthrough','Simulation','Parallel','Full-Interruption') NOT NULL,
    rto_achieved_minutes INT,
    rpo_achieved_minutes INT,
    result          ENUM('Pass','Partial','Fail') NOT NULL,
    conducted_by    VARCHAR(100),
    notes           TEXT,
    FOREIGN KEY (system_id) REFERENCES systems(system_id)
        ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 6. INCIDENTS — actual outages / DR invocations
-- ---------------------------------------------------------------------
CREATE TABLE incidents (
    incident_id     INT AUTO_INCREMENT PRIMARY KEY,
    system_id       INT NOT NULL,
    severity        ENUM('SEV1','SEV2','SEV3','SEV4') NOT NULL,
    start_time      DATETIME NOT NULL,
    resolved_time   DATETIME,
    dr_invoked      BOOLEAN DEFAULT FALSE,
    description     VARCHAR(500),
    root_cause      VARCHAR(500),
    resolution      VARCHAR(500),
    downtime_minutes INT GENERATED ALWAYS AS
        (TIMESTAMPDIFF(MINUTE, start_time, resolved_time)) STORED,
    FOREIGN KEY (system_id) REFERENCES systems(system_id)
        ON DELETE CASCADE
);

-- ---------------------------------------------------------------------
-- 7. AUTOMATION SCRIPTS — registry of automation/IaC assets
-- ---------------------------------------------------------------------
CREATE TABLE automation_scripts (
    script_id       INT AUTO_INCREMENT PRIMARY KEY,
    script_name     VARCHAR(150) NOT NULL,
    purpose         ENUM('Backup','Failover','Failback','Provisioning','Monitoring','Restore-Test') NOT NULL,
    language        VARCHAR(50),           -- Bash, Python, Terraform, Ansible
    repo_path       VARCHAR(255),          -- path/link within the GitHub repo
    system_id       INT,
    is_active       BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (system_id) REFERENCES systems(system_id)
        ON DELETE SET NULL
);

-- ---------------------------------------------------------------------
-- 8. AUTOMATION RUNS — execution history of automation scripts
-- ---------------------------------------------------------------------
CREATE TABLE automation_runs (
    run_id          BIGINT AUTO_INCREMENT PRIMARY KEY,
    script_id       INT NOT NULL,
    run_time        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status          ENUM('Success','Failed','In-Progress') NOT NULL,
    duration_seconds INT,
    triggered_by    ENUM('Scheduled','Manual','Alert-Triggered') DEFAULT 'Scheduled',
    log_summary     VARCHAR(500),
    FOREIGN KEY (script_id) REFERENCES automation_scripts(script_id)
        ON DELETE CASCADE,
    INDEX idx_runs_script_time (script_id, run_time)
);

-- ---------------------------------------------------------------------
-- Helpful view: current DR posture per system
-- ---------------------------------------------------------------------
CREATE VIEW v_system_dr_posture AS
SELECT
    s.system_id,
    s.system_name,
    s.criticality_tier,
    s.rto_target_minutes,
    s.rpo_target_minutes,
    p.strategy,
    ds.site_name AS dr_site,
    ds.site_type,
    (SELECT MAX(b.start_time) FROM backups b
        WHERE b.system_id = s.system_id AND b.status = 'Success') AS last_successful_backup,
    (SELECT MAX(t.test_date) FROM dr_tests t
        WHERE t.system_id = s.system_id AND t.result = 'Pass') AS last_passed_dr_test
FROM systems s
LEFT JOIN dr_plans p ON p.system_id = s.system_id
LEFT JOIN dr_sites ds ON ds.site_id = s.dr_site_id;
