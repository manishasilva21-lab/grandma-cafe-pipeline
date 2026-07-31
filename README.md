# Grandma's Café - End-to-End GCP Data + DevOps Project

**Repo:** `manishasilva21-lab/grandma-cafe-pipeline`
**GCP Project:** `grandma-cafe-analytics`
**Region:** `australia-southeast1`

A portfolio project demonstrating end-to-end data engineering + DevOps skills:
synthetic data generation → cloud storage → data warehouse → transformation → dashboard → automated infrastructure/CI/CD.

---

## 1. The Story / Business Problem

Grandma's café makes the best banana bread in Fitzroy, but she's convinced business is "just quiet lately." Meanwhile her sales data is quietly screaming the real story. This project builds a pipeline to prove (or disprove) that with real data.

**Ground truth baked into the synthetic data (the "answer key"):**
- Tuesdays run ~40% below normal transaction volume
- Weekends (Sat/Sun) run ~20% above normal
- Coffee sales drop sharply after 2pm (70% chance of skipping coffee)
- Muffins outsell croissants roughly 3:1

**What the pipeline proved, independently, via BigQuery + dbt:**
- Tuesday revenue: $25,157.50 vs ~$41-42k on other weekdays (~60% of normal - confirmed)
- Sunday/Saturday: highest revenue days (confirmed)
- Muffin: $93,040 total revenue (top performer)
- Croissant: $34,408 (bottom performer)

---

## 2. Architecture

```
Python (Faker-style generator)
        │
        ▼
  sales_data.csv (local)
        │
        ▼
  GCS bucket: grandma-cafe-analytics-raw-data
        │
        ▼
  BigQuery external table: cafe_data.sales_raw
        │
        ▼
  dbt Cloud
    ├── staging: stg_sales (view)
    └── marts:
          ├── sales_by_day (table) → revenue/transactions by day_of_week
          └── item_performance (table) → revenue by item
        │
        ▼
  Looker Studio dashboard (2 charts, live-connected to marts)

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
| Visualization | Looker Studio | Dashboard connected directly to BigQuery marts |
| CI/CD | GitHub Actions | Automated `terraform plan`/`apply` with approval gate |

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
├── dbt-cloud-key.json           (gitignored - service account key)
├── github-actions-key.json      (gitignored - service account key)
└── README.md
```

---

## 5. Step-by-Step Build Log

### Step 1 - Foundation
- Created GCP project `grandma-cafe-analytics`, enabled billing
- Enabled APIs: BigQuery, Cloud Storage, Cloud Build, Cloud Functions, Cloud Scheduler
- Created GitHub repo `grandma-cafe-pipeline`
- **Retroactive fix:** all API enablement later moved into Terraform (`google_project_service` with `for_each`) so the project is fully reproducible from code, not console clicks

### Step 2 - Terraform + Remote State
- Wrote `main.tf`: provider block + `google_storage_bucket.raw_data`
- Created a **separate state bucket** manually via `gsutil` (deliberately outside Terraform's own management - a bootstrap resource)
- Configured `backend "gcs"` pointing at the state bucket
- Ran `terraform init` → `plan` → `apply`
- **Bug hit:** state bucket was accidentally created under the wrong GCP project (old default project was active in local `gcloud` config at the time). Bucket *names* are globally unique in GCS but ownership is tied to whatever project is active when created - a name containing "grandma-cafe-analytics" does NOT guarantee it lives in that project.
  - **Fix:** created a new bucket (`-v2`) explicitly with `--project=grandma-cafe-analytics`, ran `terraform init -migrate-state` to move state over cleanly, verified via `terraform state list`, updated all downstream IAM bindings to point at the new bucket.

### Step 3 - Synthetic Data Generation
- Python script (`generate_sales_data.py`) using `pandas` + `random`
- Deliberately encoded ground-truth patterns (see Section 1) so the pipeline's later "discoveries" could be verified against known truth
- Verified via `groupby('day_of_week')` and time-filtered `value_counts()` before trusting the data downstream

### Step 4 - Load Raw Data to GCS
- `gcloud storage cp sales_data.csv gs://grandma-cafe-analytics-raw-data/`
- Verified upload integrity via byte-size comparison (local vs `Content-Length` in cloud) rather than trusting a checksum error caused by piping into `head` (a known false-positive - `head` closes the stream early, causing a partial-hash mismatch that looks like corruption but isn't)

### Step 5 - BigQuery External Table
- Created `cafe_data` dataset + `sales_raw` external table via Terraform, pointing at the GCS CSV (`autodetect = true`, `csv_options { skip_leading_rows = 1, quote = "" }`)
- Verified via direct SQL query grouping by day_of_week - numbers matched the synthetic data's known patterns

### Step 6 - dbt Cloud
- Set up dbt Cloud project, connected to BigQuery via a dedicated service account (`dbt-cloud-sa`)
- Three datasets used for separation of concerns:
  - `cafe_data` - raw, read-only source
  - `cafe_data_dev` - dbt's dev output
  - `cafe_data_prod` - dbt's scheduled/production output
- Built `stg_sales` (staging passthrough view) and two marts:
  - `sales_by_day` - one row per day_of_week, total_revenue + transaction_count
  - `item_performance` - one row per item, total_revenue_per_item
- Also configured local dbt Cloud CLI in VS Code for local development against the same dbt Cloud project

### Step 7 - Looker Studio Dashboard
- Connected both marts as BigQuery data sources
- Built two bar charts: revenue by day (sorted descending), revenue by item (sorted descending)
- Confirmed visually: Tuesday is the clear underperformer, Muffin is the clear top seller

### Step 8 - CI/CD (GitHub Actions)
- Two-job workflow: `plan` (runs on PR, read-only) → `apply` (runs on push to `main`, gated by manual approval via a GitHub `production` Environment with required reviewers)
- Dedicated service account `github-actions-sa` with `roles/editor` at project level (documented trade-off: broader than strict least-privilege, acceptable for a solo project, would be scoped tighter in a team setting)
- PR-based workflow: merged `work_branch_manisha` → `main` via a real pull request before wiring CI/CD to the default branch

---

## 6. Real Bugs Encountered (and why they matter)

This project's actual value isn't "followed a tutorial" - it's the debugging. Every one of these was a genuine, independently-diagnosed issue:

| Bug | Root Cause | Fix |
|---|---|---|
| Empty GitHub repo despite "done" | Commands were never actually run, just assumed | Verified via direct repo fetch; ran real git commands |
| `terraform apply` never run before backend migration | Sequence confusion (backend configured before first apply) | Clarified timeline; ran `plan`→`apply` in correct order |
| dbt Cloud `AuthenticationFailed` / Storage API error | BigQuery **Storage Read API** requires `bigquery.readsessions.create`, not covered by `dataEditor`/`jobUser` alone | Added `roles/bigquery.user` to service account via Terraform |
| Same error persisted after "fixing" region | Region was a red herring; real cause was the dataset (`cafe_data_dev`) not existing yet | Created datasets via Terraform before retrying |
| dbt Cloud CLI vs dbt-core conflict | Local `venv` had a conflicting `dbt` binary shadowing the correct dbt Cloud CLI | Deactivated venv; understood the two tools share a command name but are incompatible |
| YAML `SerializationError` in `dbt_project.yml` | Stray non-YAML text appended to the file | Rewrote with a complete, valid `dbt_project.yml` |
| `dbt build` selection failing ("nothing to do") | Wrong `-s` syntax (full file path instead of model name) | Used `dbt build -s <model_name>` |
| `sales_by_day` "table not found: raw_sales" | CTE naming mismatch - referenced a CTE name that didn't match its actual definition | Renamed consistently, always cross-checked before running |
| `sales_by_day` GCS permission denied | Views query live down to the raw external table; `dbt-cloud-sa` had BigQuery permissions but no GCS bucket read access | Added `roles/storage.objectViewer` scoped to the specific bucket |
| GitHub Actions `terraform init` - wrong working directory | Actual folder was `Infra/terraform/`, workflow assumed `terraform/` | Updated both the trigger `paths:` filter and `working-directory:` in the workflow |
| Workflow silently not triggering | GitHub Actions path filters do **not** make an exception for changes to the workflow file itself - a commit only touching `.github/workflows/*.yml` won't satisfy a `paths: - 'Infra/terraform/**'` filter | Included a real change under the watched path to trigger a test run |
| GitHub Actions `terraform init` - Storage API 403 on state bucket | **Root cause:** the state bucket was created under an entirely different (old/personal) GCP project than `grandma-cafe-analytics`, due to `gsutil mb` using whatever project was locally active at creation time. `github-actions-sa` has zero access to that unrelated project, so no amount of IAM tweaking on the "right" project would ever fix it. | Migrated to a new, correctly-owned bucket via `terraform init -migrate-state`; verified via `terraform state list` |

**The meta-lesson:** most of these bugs were "invisible" locally because a personal Google account tends to have broad access across many projects/resources, masking permission and ownership issues that only surface once a narrowly-scoped service account (dbt's, then GitHub Actions') tries the same operation. This is a genuinely important, realistic lesson about the difference between "it works on my machine" and "it works for the system that actually needs to run it unattended."

---

## 7. Key IAM Setup (Terraform-managed)

**`dbt-cloud-sa`** - used by dbt Cloud to read/transform data:
- `roles/bigquery.dataEditor` - write models
- `roles/bigquery.jobUser` - run query jobs
- `roles/bigquery.user` - required for BigQuery Storage Read API (readsessions)
- `roles/storage.objectViewer` (bucket-scoped, `raw_data` bucket only) - read the raw CSV underlying the external table

**`github-actions-sa`** - used by CI/CD to manage infrastructure:
- `roles/editor` (project-level) - broad, pragmatic choice for a solo project; would be scoped to a custom role in a team/production setting
- `roles/storage.objectAdmin` (bucket-scoped, tfstate bucket only) - read/write Terraform state

**Secrets management:**
- Service account keys (`dbt-cloud-key.json`, `github-actions-key.json`) generated manually via `gcloud iam service-accounts keys create` - deliberately *not* Terraform-managed, since key material shouldn't sit in `.tfstate` in plaintext
- Both keys immediately gitignored
- GitHub Actions key stored as repository secret `GCP_SA_KEY`

---

## 8. Useful Commands Reference

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
```

---

## 9. What's Left / Next Steps

- [ ] Confirm GitHub Actions `apply` job correctly pauses at the `production` environment approval gate after merging to `main`
- [ ] Add a scheduled dbt Cloud job (or Cloud Scheduler + Cloud Function) so marts rebuild automatically on a cadence, not just manually
- [ ] Chaos/DR-lite test: deliberately break something (delete a table, revoke a permission) and prove the pipeline/alerts surface it
- [ ] Polish Looker Studio dashboard: title, one-line insight callout, consistent snake_case column naming throughout
- [ ] Consider adding dbt tests (`not_null`, `accepted_values`) to the marts for a data-quality story

---

## 10. Talking Points for Interviews

- "I built this end-to-end myself, including debugging a service account permission chain across BigQuery, GCS, and IAM - not just following a tutorial."
- "I deliberately used synthetic data with known statistical patterns so I could verify my pipeline was correct at every stage, not just that it produced *a* result."
- "I hit a real production-realistic bug where my Terraform state bucket was silently living under the wrong GCP project - invisible with my personal credentials, but broke immediately for a narrowly-scoped CI/CD service account. I diagnosed and migrated it via `terraform init -migrate-state` without losing any state."
- "My CI/CD pipeline separates plan (automatic, safe) from apply (gated behind manual approval), which reflects how I'd actually want production infrastructure changes handled on a real team."