terraform {
    required_providers {
        google = {
            source = "hashicorp/google"
            version = "~>5.0"
        }
        archive = {
        source  = "hashicorp/archive"
        version = "~> 2.4"
        }
    }

  backend "gcs" {
  bucket = "grandma-cafe-analytics-tfstate-v2"
  prefix = "terraform/state"
}

}


locals {
  enabled_apis = [
    "bigquery.googleapis.com",
    "bigquerystorage.googleapis.com",
    "storage.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudscheduler.googleapis.com",
    "compute.googleapis.com",
    "run.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.enabled_apis)

  project = "grandma-cafe-analytics"
  service = each.value

  disable_on_destroy = false
}

provider "google" {
    project = "grandma-cafe-analytics"
    region = "australia-southeast1"
}

resource "google_storage_bucket" "raw_data" {
    name = "grandma-cafe-analytics-raw-data"
    location = "australia-southeast1"
    force_destroy = true

    uniform_bucket_level_access = true
}

resource "google_bigquery_dataset" "cafe_data" {
  dataset_id = "cafe_data"
  location   = "australia-southeast1"
  description = "Grandma's café raw and modeled sales data"
}

resource "google_bigquery_table" "sales_raw" {
  dataset_id = google_bigquery_dataset.cafe_data.dataset_id
  table_id   = "sales_raw"

  external_data_configuration {
    source_format = "CSV"
    autodetect    = true #figure out column types by itself

    csv_options {
        quote = ""
      skip_leading_rows = 1 #skip the head row
    }

    source_uris = [
    "gs://grandma-cafe-analytics-raw-data/sales_*.csv"
    ]
  }

  deletion_protection = false
}

#dbt service account and its permissions
resource "google_service_account" "dbt_cloud_sa" {
  account_id   = "dbt-cloud-sa"
  display_name = "dbt Cloud Service Account"
}

resource "google_project_iam_member" "dbt_bigquery_editor" {
  project = "grandma-cafe-analytics"
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.dbt_cloud_sa.email}"
}

resource "google_project_iam_member" "dbt_bigquery_jobuser" {
  project = "grandma-cafe-analytics"
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.dbt_cloud_sa.email}"
}

#apis
resource "google_project_service" "bigquery_storage_api" {
  project = "grandma-cafe-analytics"
  service = "bigquerystorage.googleapis.com"

  disable_on_destroy = false
}

resource "google_bigquery_dataset" "cafe_data_dev" {
  dataset_id  = "cafe_data_dev"
  location    = "australia-southeast1"
  description = "Development dataset for dbt models - Grandma's café"
}

resource "google_bigquery_dataset" "cafe_data_prod" {
  dataset_id  = "cafe_data_prod"
  location    = "australia-southeast1"
  description = "Production dataset for dbt models - Grandma's café"
}

resource "google_project_iam_member" "dbt_bigquery_user" {
  project = "grandma-cafe-analytics"
  role    = "roles/bigquery.user"
  member  = "serviceAccount:${google_service_account.dbt_cloud_sa.email}"
}

resource "google_storage_bucket_iam_member" "dbt_sa_storage_viewer" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.dbt_cloud_sa.email}"
}

resource "google_service_account" "github_actions_sa" {
  account_id   = "github-actions-sa"
  display_name = "GitHub Actions CI/CD Service Account"
}

resource "google_project_iam_member" "github_actions_editor" {
  project = "grandma-cafe-analytics"
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.github_actions_sa.email}"
}

resource "google_storage_bucket_iam_member" "github_actions_tfstate_access" {
  bucket = "grandma-cafe-analytics-tfstate-v2"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.github_actions_sa.email}"
}

resource "google_service_account" "daily_generator_sa" {
  account_id   = "daily-generator-sa"
  display_name = "Daily Sales Generator Cloud Function"
}
#only object creator coz it just have to create the new file
resource "google_storage_bucket_iam_member" "generator_storage_write" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.daily_generator_sa.email}"
}

#cloud function
resource "google_storage_bucket" "function_source" {
  name     = "grandma-cafe-analytics-function-source"
  location = "australia-southeast1"
  uniform_bucket_level_access = true
}

data "archive_file" "function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../../cloud-function"
  output_path = "${path.module}/function.zip"
}

resource "google_storage_bucket_object" "function_zip" {
  name   = "function-${data.archive_file.function_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.function_zip.output_path
}

resource "google_cloudfunctions2_function" "daily_generator" {
  name     = "daily-sales-generator"
  location = "australia-southeast1"

   depends_on = [
    google_project_service.apis
  ]

  build_config {
    runtime     = "python312"
    entry_point = "generate_daily_sales"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.function_zip.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory    = "256M"
    timeout_seconds      = 60
    service_account_email = google_service_account.daily_generator_sa.email
  }
}

#cloud scheduler
resource "google_cloud_scheduler_job" "daily_sales_trigger" {
  name      = "trigger-daily-sales-generator"
  region    = "australia-southeast1"
  schedule  = "0 5 * * *"
  time_zone = "Australia/Melbourne"

  http_target {
    uri         = google_cloudfunctions2_function.daily_generator.service_config[0].uri
    http_method = "POST"

    oidc_token {
      service_account_email = google_service_account.daily_generator_sa.email
    }
  }

  depends_on = [
    google_cloudfunctions2_function.daily_generator
  ]
}

resource "google_cloud_run_service_iam_member" "scheduler_invoker" {
  location = "australia-southeast1"
  service  = google_cloudfunctions2_function.daily_generator.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.daily_generator_sa.email}"
}

resource "google_project_iam_member" "github_actions_run_admin" {
  project = "grandma-cafe-analytics"
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.github_actions_sa.email}"
}