# Grandma's Café - End-to-End GCP Data + DevOps Project

**Repo:** `manishasilva21-lab/grandma-cafe-pipeline`
**GCP Project:** `grandma-cafe-analytics`
**Region:** `australia-southeast1`

A portfolio project demonstrating end-to-end data engineering + DevOps skills:
synthetic data generation → cloud storage → data warehouse → transformation → dashboard → automated infrastructure/CI/CD.

---

## 1. The Story / Business Problem

Brownstone café makes the best banana bread in Fitzroy, but she's convinced business is "just quiet lately." Meanwhile her sales data is quietly screaming the real story. This project builds a pipeline to prove (or disprove) that with real data.

**Ground truth baked into the synthetic data (the "answer key"):**
- Tuesdays run ~40% below normal transaction volume
- Weekends (Sat/Sun) run ~20% above normal
- Coffee sales drop sharply after 2pm (70% chance of skipping coffee)
- Muffins outsell croissants roughly 3:1

**What the pipeline proved, independently, via BigQuery + dbt:**
- Tuesday revenue: $25,157.50 vs ~$41-42k on other weekdays (~60% of normal — confirmed)
- Sunday/Saturday: highest revenue days (confirmed)
- Muffin: $93,040 total revenue (top performer)
- Croissant: $34,408 (bottom performer)

---

## 2. Architecture

```
Cloud Scheduler (fires 5am daily, Australia/Melbourne)
        │
        ▼
Cloud Function "daily-sales-generator" (Python, timezone-aware "yesterday")
        │
        ▼
  GCS bucket: grandma-cafe-analytics-raw-data
    ├── historical/sales_data.csv     (original one-year seed dataset, retired)
    └── sales_YYYY-MM-DD.csv          (one file per day, ongoing)
        │
        ▼
  BigQuery external table: cafe_data.sales_raw
    (source_uris wildcard: gs://.../sales_*.csv — reads ALL dated files as one table)
        │
        ▼
  dbt Cloud
    ├── staging: stg_sales (view)
    └── marts:
          ├── sales_by_day (table) → revenue/transactions by day_of_week
          └── item_performance (table) → revenue by item
    Environments: cafe_data_dev (manual/dev runs) → cafe_data_prod (daily scheduled job)
        │
        ▼
  Looker Studio dashboard (2 charts, connected to cafe_data_prod)

Infrastructure (all of the above's plumbing) = Terraform, remote state in GCS
CI/CD = GitHub Actions (Terraform plan/apply with manual approval gate)
```

---

## 3. Tech Stack

| Layer | Tool | Purpose |
|---|---|---|
| Version control | GitHub | Source of truth for all code |
| IaC | Terraform (GCS remote backend) | Provision all GCP resources reproducibly |
| Data generation | Python (pandas, random) | Synthetic café sales data with known patterns |
| Raw storage | Google Cloud Storage | Landing zone for raw CSV |
| Warehouse | BigQuery (external table) | Query raw data without duplicating storage |
| Transformation | dbt Cloud | Staging + mart models, tests |
| Visualization | Looker Studio | Dashboard connected directly to BigQuery marts (prod dataset) |
| CI/CD | GitHub Actions | Automated `terraform plan`/`apply` with approval gate |
| Daily automation | Cloud Scheduler + Cloud Functions (2nd gen) | Generates and uploads a new day's transactions automatically, every day |

---

## 4. Project Structure

```
grandma-cafe-pipeline/
├── .github/
│   └── workflows/
│       └── terraform.yml
├── Infra/
│   └── terraform/
│       ├── main.tf
│       ├── .terraform/          (gitignored)
│       └── *.tfstate            (remote, not local)
├── data-generator/
│   ├── generate_sales_data.py
│   └── requirements.txt
├── dbt/  (or wherever dbt_project.yml lives)
│   ├── dbt_project.yml
│   ├── dbt_cloud.yml            (gitignored-adjacent; dbt Cloud CLI link)
│   └── models/
│       ├── staging/
│       │   ├── sources.yml
│       │   └── stg_sales.sql
│       └── marts/
│           ├── sales_by_day.sql
│           └── item_performance.sql
├── dbt-cloud-key.json           (gitignored — service account key)
├── github-actions-key.json      (gitignored — service account key)
└── README.md
```

---

## 5. Step-by-Step Build Log

### Step 1 — Foundation
- Created GCP project `grandma-cafe-analytics`, enabled billing
- Enabled APIs: BigQuery, Cloud Storage, Cloud Build, Cloud Functions, Cloud Scheduler
- Created GitHub repo `grandma-cafe-pipeline`
- **Retroactive fix:** all API enablement later moved into Terraform (`google_project_service` with `for_each`) so the project is fully reproducible from code, not console clicks

### Step 2 — Terraform + Remote State
- Wrote `main.tf`: provider block + `google_storage_bucket.raw_data`
- Created a **separate state bucket** manually via `gsutil` (deliberately outside Terraform's own management — a bootstrap resource)
- Configured `backend "gcs"` pointing at the state bucket
- Ran `terraform init` → `plan` → `apply`
- **Bug hit:** state bucket was accidentally created under the wrong GCP project (old default project was active in local `gcloud` config at the time). Bucket *names* are globally unique in GCS but ownership is tied to whatever project is active when created — a name containing "grandma-cafe-analytics" does NOT guarantee it lives in that project.
  - **Fix:** created a new bucket (`-v2`) explicitly with `--project=grandma-cafe-analytics`, ran `terraform init -migrate-state` to move state over cleanly, verified via `terraform state list`, updated all downstream IAM bindings to point at the new bucket.

### Step 3 — Synthetic Data Generation
- Python script (`generate_sales_data.py`) using `pandas` + `random`
- Deliberately encoded ground-truth patterns (see Section 1) so the pipeline's later "discoveries" could be verified against known truth
- Verified via `groupby('day_of_week')` and time-filtered `value_counts()` before trusting the data downstream

### Step 4 — Load Raw Data to GCS
- `gcloud storage cp sales_data.csv gs://grandma-cafe-analytics-raw-data/`
- Verified upload integrity via byte-size comparison (local vs `Content-Length` in cloud) rather than trusting a checksum error caused by piping into `head` (a known false-positive — `head` closes the stream early, causing a partial-hash mismatch that looks like corruption but isn't)

### Step 5 — BigQuery External Table
- Created `cafe_data` dataset + `sales_raw` external table via Terraform, pointing at the GCS CSV (`autodetect = true`, `csv_options { skip_leading_rows = 1, quote = "" }`)
- Verified via direct SQL query grouping by day_of_week — numbers matched the synthetic data's known patterns

### Step 6 — dbt Cloud
- Set up dbt Cloud project, connected to BigQuery via a dedicated service account (`dbt-cloud-sa`)
- Three datasets used for separation of concerns:
  - `cafe_data` — raw, read-only source
  - `cafe_data_dev` — dbt's dev output
  - `cafe_data_prod` — dbt's scheduled/production output
- Built `stg_sales` (staging passthrough view) and two marts:
  - `sales_by_day` — one row per day_of_week, total_revenue + transaction_count
  - `item_performance` — one row per item, total_revenue_per_item
- Also configured local dbt Cloud CLI in VS Code for local development against the same dbt Cloud project

### Step 7 — Looker Studio Dashboard
- Connected both marts as BigQuery data sources
- Built two bar charts: revenue by day (sorted descending), revenue by item (sorted descending)
- Confirmed visually: Tuesday is the clear underperformer, Muffin is the clear top seller

### Step 8 — CI/CD (GitHub Actions)
- Two-job workflow: `plan` (runs on PR, read-only) → `apply` (runs on push to `main`, gated by manual approval via a GitHub `production` Environment with required reviewers)
- Dedicated service account `github-actions-sa` with `roles/editor` at project level (documented trade-off: broader than strict least-privilege, acceptable for a solo project, would be scoped tighter in a team setting)
- PR-based workflow: merged `work_branch_manisha` → `main` via a real pull request before wiring CI/CD to the default branch

### Step 8b — dbt Production Job + Dashboard Repoint
- Discovered a real gap: the GitHub Actions pipeline only automates **Terraform** (infra), not **dbt** (data transformation) — merging to `main` never builds anything into `cafe_data_prod` on its own
- Created a dbt Cloud **Job** tied to the Production environment, scheduled daily (realistic cadence for a café, not an arbitrary demo-friendly interval)
- Fixed a dbt Cloud project-subdirectory setting (project lives in a subfolder, not repo root) that was causing job runs to fail with "valid dbt project not found"
- Verified real tables landed in `cafe_data_prod` via `INFORMATION_SCHEMA.TABLES`, not just trusting a green checkmark
- Repointed both Looker Studio data sources from `cafe_data_dev` to `cafe_data_prod`, so the dashboard reflects the scheduled production pipeline rather than ad hoc dev runs

### Step 9 — Daily Automated Data Ingestion (Cloud Function + Cloud Scheduler)
Goal: make the pipeline feel "alive" — new transaction data appearing daily without manual intervention.

**Design decisions made deliberately, not defaulted into:**
- New data lands as **one dated file per day** (`sales_YYYY-MM-DD.csv`), matching how a real POS system would export, rather than one ever-growing file
- The BigQuery external table's `source_uris` was updated to a **wildcard pattern** (`gs://.../sales_*.csv`) so it transparently reads all dated files as one logical table
- The original full-year seed file was retired to a `historical/` prefix so it wouldn't double-count against the wildcard
- The function generates data for **yesterday**, not "today" — a business day isn't complete until it's over, so writing an in-progress day's totals would be premature (a real ETL/batch-processing principle, not just a taste choice)

**Build sequence:**
1. **One-time historical backfill** — modified the original generator to loop from a fixed start date through "today," writing one CSV per day locally first, verified the day-of-week pattern still held (`Tuesday` count ≈ 60% of other weekdays) before uploading anything
2. Uploaded all backfilled files to GCS, verified BigQuery's wildcard table read all of them correctly (`COUNT(DISTINCT date)` matched file count)
3. Manually triggered the dbt Cloud production job to confirm the enlarged dataset flowed through to `cafe_data_prod` and the Looker Studio dashboard
4. Built `cloud-function/main.py` — an HTTP-triggered Cloud Function (2nd gen) that generates one day's transactions and uploads directly to GCS via `blob.upload_from_string()` (no local disk involved, since Cloud Functions' filesystem isn't suited for persistent file writes)
5. Provisioned via Terraform: a dedicated `daily-generator-sa` service account (scoped to `roles/storage.objectCreator` on the raw-data bucket only), a separate function-source staging bucket, an `archive_file` data source to auto-zip the function code, and the `google_cloudfunctions2_function` resource itself
6. Added `google_cloud_scheduler_job` (cron `0 5 * * *`, `Australia/Melbourne`) plus a `google_cloud_run_service_iam_member` granting the generator's own service account `roles/run.invoker`, so Cloud Scheduler can authenticate and invoke the function via OIDC token

---


## 6. Key IAM Setup (Terraform-managed)

**`dbt-cloud-sa`** — used by dbt Cloud to read/transform data:
- `roles/bigquery.dataEditor` — write models
- `roles/bigquery.jobUser` — run query jobs
- `roles/bigquery.user` — required for BigQuery Storage Read API (readsessions)
- `roles/storage.objectViewer` (bucket-scoped, `raw_data` bucket only) — read the raw CSV underlying the external table

**`github-actions-sa`** — used by CI/CD to manage infrastructure:
- `roles/editor` (project-level) — broad, pragmatic choice for a solo project; would be scoped to a custom role in a team/production setting
- `roles/storage.objectAdmin` (bucket-scoped, tfstate bucket only) — read/write Terraform state
- `roles/run.admin` (project-level) — required to manage Cloud Run/Cloud Functions IAM policy; **granted manually via personal Owner-level credentials and brought into Terraform via `terraform import`**, since `github-actions-sa` structurally cannot grant this role to itself (GCP blocks self-escalation by design)

**`daily-generator-sa`** — used by the Cloud Function to generate and upload daily sales data:
- `roles/storage.objectCreator` (bucket-scoped, `raw_data` bucket only) — can create new files, deliberately cannot overwrite/delete existing ones
- `roles/run.invoker` (on its own Cloud Run service) — allows Cloud Scheduler, authenticating as this same service account via OIDC, to invoke the function

**Secrets management:**
- Service account keys (`dbt-cloud-key.json`, `github-actions-key.json`) generated manually via `gcloud iam service-accounts keys create` — deliberately *not* Terraform-managed, since key material shouldn't sit in `.tfstate` in plaintext
- Both keys immediately gitignored
- GitHub Actions key stored as repository secret `GCP_SA_KEY`

---

## 7. Useful Commands Reference

```bash
# Terraform
terraform init                       # initialize / configure backend
terraform init -migrate-state        # move state to a new backend
terraform plan                       # preview changes
terraform apply                      # apply changes
terraform state list                 # see everything Terraform is tracking
terraform import <resource> <id>     # bring an existing resource under management

# GCP
gcloud storage buckets list --project=<project>
gcloud storage buckets get-iam-policy gs://<bucket>
gcloud projects describe <project-id> --format="value(projectNumber)"
gcloud iam service-accounts keys create <file>.json --iam-account=<sa-email>

# BigQuery
bq query --use_legacy_sql=false 'SELECT ...'
bq ls --project_id=<project>

# dbt
dbt debug                            # test connection
dbt run --select <model>             # build one model
dbt build -s <model>                 # build + test one model
dbt show -s <model>                  # preview a model's output without a separate query

# Git
git rm -r --cached <path>            # untrack a file/folder without deleting it locally
git reset --soft <commit>            # rewind branch pointer, keep changes staged

# Cloud Functions / Scheduler
gcloud functions describe <name> --region=<region> --gen2
gcloud functions call <name> --region=<region> --gen2
gcloud functions logs read <name> --region=<region> --gen2 --limit=50
gcloud scheduler jobs describe <name> --location=<region>
gcloud scheduler jobs run <name> --location=<region>       # manually fire a scheduled job now
```

---

## 8. What's Left / Next Steps

- [x] ~~Confirm GitHub Actions `apply` job correctly pauses at the `production` environment approval gate~~ — confirmed working
- [x] ~~Add a scheduled dbt Cloud job so marts rebuild automatically~~ — daily dbt Cloud job live, verified writing to `cafe_data_prod`
- [x] ~~Cloud Function + Cloud Scheduler for daily data ingestion~~ — built, deployed via CI/CD, timezone bug found and fixed
- [ ] **Decide and implement final overwrite behavior** for `daily-generator-sa`: broaden to `objectAdmin` (allow safe re-runs) vs. add explicit check-and-skip logic in `main.py` if a file for that date already exists — currently an open decision, only bites if the function runs twice for the same date
- [ ] Confirm the first fully unattended scheduled run (5am Melbourne, no manual trigger) produces a correctly-dated file with no intervention
- [ ] Chaos/DR-lite test: deliberately break something (delete a table, revoke a permission) and prove the pipeline/alerts surface it
- [ ] Polish Looker Studio dashboard: title, one-line insight callout, consistent snake_case column naming throughout
- [ ] Consider adding dbt tests (`not_null`, `accepted_values`) to the marts for a data-quality story

