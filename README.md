# Disaster-Recovery-Backup-Automation

## 1. Objectives

| Metric | Target | Definition |
|---|---|---|
| **RPO** (Recovery Point Objective) | 15 minutes | Max acceptable data loss |
| **RTO** (Recovery Time Objective) | 1 hour | Max acceptable downtime |
| **RTO — full region loss** | 4 hours | Cross-region failover, worst case |

If actual recovery time during a drill or incident exceeds these targets, that's the signal to invest further in automation, not to move the goalposts.

---

## 2. Backup Inventory

| Asset | Backup method | Frequency | Location | Retention |
|---|---|---|---|---|
| RDS / primary DB | AWS Backup snapshot (PITR-capable) | Continuous + daily snapshot | Primary + DR region vault | 35d daily / 180d weekly / 7yr monthly |
| DB logical dump | `scripts/db_backup.sh` (pg_dump/mysqldump) | Daily, 03:00 UTC | S3 (`my-org-db-backups`), replicated to DR region | 35d → Glacier at 90d → expire 365d |
| EBS volumes | AWS Backup | Daily | Primary + DR vault | 35d |
| Application config / secrets | Git + secrets manager versioning | On every change | GitHub + AWS Secrets Manager | Indefinite (git history) |
| Terraform state | S3 backend with versioning | On every apply | S3 (separate state bucket) | Indefinite |
| Container images | Registry with immutable tags | On every build | ECR, replicated cross-region | 90d for untagged, indefinite for release tags |

**S3 Object Lock** and **AWS Backup Vault Lock** are enabled on primary backup stores — this means backups can't be deleted even by a compromised admin account during the lock window. This is the specific defense against ransomware that also targets your backups.
