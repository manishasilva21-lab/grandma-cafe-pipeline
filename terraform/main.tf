terraform {
    required_providers {
        google = {
            source = "hashicorp/google"
            version = "~>5.0"
        }
    }

    backend "gcs" {
        bucket = "grandma-cafe-analytics-tfstate"
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
      "gs://grandma-cafe-analytics-raw-data/sales_data.csv"
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