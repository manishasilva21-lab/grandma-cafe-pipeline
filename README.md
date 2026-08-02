# Grandma's Café — End-to-End GCP Data + DevOps Project

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

## 6. Real Bugs Encountered (and why they matter)

This project's actual value isn't "followed a tutorial" — it's the debugging. Every one of these was a genuine, independently-diagnosed issue:

| Bug | Root Cause | Fix |
|---|---|---|
| Empty GitHub repo despite "done" | Commands were never actually run, just assumed | Verified via direct repo fetch; ran real git commands |
| `terraform apply` never run before backend migration | Sequence confusion (backend configured before first apply) | Clarified timeline; ran `plan`→`apply` in correct order |
| dbt Cloud `AuthenticationFailed` / Storage API error | BigQuery **Storage Read API** requires `bigquery.readsessions.create`, not covered by `dataEditor`/`jobUser` alone | Added `roles/bigquery.user` to service account via Terraform |
| Same error persisted after "fixing" region | Region was a red herring; real cause was the dataset (`cafe_data_dev`) not existing yet | Created datasets via Terraform before retrying |
| dbt Cloud CLI vs dbt-core conflict | Local `venv` had a conflicting `dbt` binary shadowing the correct dbt Cloud CLI | Deactivated venv; understood the two tools share a command name but are incompatible |
| YAML `SerializationError` in `dbt_project.yml` | Stray non-YAML text appended to the file | Rewrote with a complete, valid `dbt_project.yml` |
| `dbt build` selection failing ("nothing to do") | Wrong `-s` syntax (full file path instead of model name) | Used `dbt build -s <model_name>` |
| `sales_by_day` "table not found: raw_sales" | CTE naming mismatch — referenced a CTE name that didn't match its actual definition | Renamed consistently, always cross-checked before running |
| `sales_by_day` GCS permission denied | Views query live down to the raw external table; `dbt-cloud-sa` had BigQuery permissions but no GCS bucket read access | Added `roles/storage.objectViewer` scoped to the specific bucket |
| GitHub Actions `terraform init` — wrong working directory | Actual folder was `Infra/terraform/`, workflow assumed `terraform/` | Updated both the trigger `paths:` filter and `working-directory:` in the workflow |
| Workflow silently not triggering | GitHub Actions path filters do **not** make an exception for changes to the workflow file itself — a commit only touching `.github/workflows/*.yml` won't satisfy a `paths: - 'Infra/terraform/**'` filter | Included a real change under the watched path to trigger a test run |
| GitHub Actions `terraform init` — Storage API 403 on state bucket | **Root cause:** the state bucket was created under an entirely different (old/personal) GCP project than `grandma-cafe-analytics`, due to `gsutil mb` using whatever project was locally active at creation time. `github-actions-sa` has zero access to that unrelated project, so no amount of IAM tweaking on the "right" project would ever fix it. | Migrated to a new, correctly-owned bucket via `terraform init -migrate-state`; verified via `terraform state list` |
| `gcloud` commands failing with "resource not found" against real resources | Local `gcloud` CLI's default project had been the old/wrong project (`cost-tracker-demo-manisha-h`) this entire session — same root cause as the tfstate bucket bug, discovered again independently | `gcloud config set project grandma-cafe-analytics` — set explicitly rather than relying on an assumed default |
| Cloud Function deploy — `service account ... was not found` | Cloud Functions 2nd gen builds via Cloud Build/Cloud Run under the hood, which needs the **default Compute Engine service account** — never created because `compute.googleapis.com` had never been enabled (no VMs ever used in this project) | Added `compute.googleapis.com` (and `run.googleapis.com`, needed next) to the Terraform-managed API list |
| Cloud Function deploy — "Cloud Run Admin API has not been used" | Classic race condition: API enablement and function creation ran in the same apply with no explicit ordering, so the API hadn't finished propagating before the function tried to use it | Added `depends_on = [google_project_service.apis]` on the function resource to force correct sequencing |
| Cloud Function runtime — `403 storage.objects.delete` on upload | `daily-generator-sa` had `roles/storage.objectCreator`, which permits creating **new** objects but not overwriting existing ones. The target filename already existed from an earlier manual/backfill run for the same date | Manually deleted the colliding file for the one-off collision; left as an open design decision (broaden to `objectAdmin` vs. add explicit skip-if-exists logic) since it only recurs if the function runs twice for the same date |
| Cloud Scheduler → Function: `403 the request was not authenticated` | IAM propagation delay — the `run.invoker` binding was created moments before the scheduled trigger fired | Waited, re-triggered manually; succeeded once permissions had propagated |
| `github-actions-sa` — `run.services.setIamPolicy` denied | `roles/editor` deliberately excludes the ability to **set IAM policy** on resources, even ones it can otherwise fully manage — a real GCP security boundary preventing indirect privilege escalation | Attempted fix (grant `roles/run.admin` to the SA via Terraform, using the SA itself) also failed for the identical reason one level up |
| `github-actions-sa` — `Policy update access denied` on granting itself `roles/run.admin` | **Structural boundary, not a bug:** a service account can never grant itself (or anyone) more IAM authority than it already has — Terraform running *as* `github-actions-sa` cannot escalate its own privileges, by design | Granted the role manually via personal (Owner-level) credentials, then used `terraform import` to bring the binding under state tracking without ever letting the pipeline attempt to create it |
| Daily generator producing the wrong date | Function computed "yesterday" using `datetime.now()`, which runs in **UTC** on Google's servers — not Melbourne time, where the café (and the Scheduler's cron) actually operates. A job firing at 5am Melbourne time is still the previous UTC day, silently shifting every calculation off by one | Used `datetime.now(ZoneInfo("Australia/Melbourne"))` explicitly — never trust server-local time for business-date logic |
| `function.zip` and `.terraform.lock.hcl` — which to commit? | Easy to lump both together as "build junk" | `.terraform.lock.hcl` **should** be committed (pins provider versions, prevents drift between local/CI); `function.zip` should **not** (auto-regenerated by `archive_file` on every apply, pure build output) |

**The meta-lesson:** most of these bugs were "invisible" locally because a personal Google account tends to have broad access across many projects/resources, masking permission and ownership issues that only surface once a narrowly-scoped service account (dbt's, then GitHub Actions') tries the same operation. This is a genuinely important, realistic lesson about the difference between "it works on my machine" and "it works for the system that actually needs to run it unattended."

---

## 7. Key IAM Setup (Terraform-managed)

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

# Cloud Functions / Scheduler
gcloud functions describe <name> --region=<region> --gen2
gcloud functions call <name> --region=<region> --gen2
gcloud functions logs read <name> --region=<region> --gen2 --limit=50
gcloud scheduler jobs describe <name> --location=<region>
gcloud scheduler jobs run <name> --location=<region>       # manually fire a scheduled job now
```

---

## 9. What's Left / Next Steps

- [x] ~~Confirm GitHub Actions `apply` job correctly pauses at the `production` environment approval gate~~ — confirmed working
- [x] ~~Add a scheduled dbt Cloud job so marts rebuild automatically~~ — daily dbt Cloud job live, verified writing to `cafe_data_prod`
- [x] ~~Cloud Function + Cloud Scheduler for daily data ingestion~~ — built, deployed via CI/CD, timezone bug found and fixed
- [ ] **Decide and implement final overwrite behavior** for `daily-generator-sa`: broaden to `objectAdmin` (allow safe re-runs) vs. add explicit check-and-skip logic in `main.py` if a file for that date already exists — currently an open decision, only bites if the function runs twice for the same date
- [ ] Confirm the first fully unattended scheduled run (5am Melbourne, no manual trigger) produces a correctly-dated file with no intervention
- [ ] Chaos/DR-lite test: deliberately break something (delete a table, revoke a permission) and prove the pipeline/alerts surface it
- [ ] Polish Looker Studio dashboard: title, one-line insight callout, consistent snake_case column naming throughout
- [ ] Consider adding dbt tests (`not_null`, `accepted_values`) to the marts for a data-quality story

---

## 10. Talking Points for Interviews

- "I built this end-to-end myself, including debugging a service account permission chain across BigQuery, GCS, and IAM — not just following a tutorial."
- "I deliberately used synthetic data with known statistical patterns so I could verify my pipeline was correct at every stage, not just that it produced *a* result."
- "I hit a real production-realistic bug where my Terraform state bucket was silently living under the wrong GCP project — invisible with my personal credentials, but broke immediately for a narrowly-scoped CI/CD service account. I diagnosed and migrated it via `terraform init -migrate-state` without losing any state."
- "My CI/CD pipeline separates plan (automatic, safe) from apply (gated behind manual approval), which reflects how I'd actually want production infrastructure changes handled on a real team."
- "I hit GCP's built-in protection against privilege self-escalation firsthand — my CI/CD service account couldn't grant itself a new IAM role, by design. I resolved it correctly: a human with real Owner-level access granted it once, and I brought that single binding under Terraform's tracking with `terraform import`, rather than trying to force the automation to do something it structurally shouldn't be able to do."
- "I found and fixed a genuine timezone bug in my daily automation — a Cloud Function computing 'yesterday' using server-side UTC time instead of the business's actual timezone (Melbourne), which would have silently generated data for the wrong date, forever, if I hadn't caught it by checking actual output rather than trusting a success message."
- "I designed the daily ingestion to land as one dated file per day, matching how a real point-of-sale system exports data, and updated my BigQuery external table to a wildcard source pattern so new files are picked up automatically with zero schema or pipeline changes needed."