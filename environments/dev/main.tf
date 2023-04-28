# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

locals {
  env = "dev"
}

provider "google" {
  project = var.project
  region = var.region
  zone = var.zone
}

resource "random_id" "bucket_prefix" {
  byte_length = 8
}

module "vpc" {
  source  = "../../modules/vpc"
  project = var.project
  env     = local.env
}

# module "http_server" {
#   source  = "../../modules/http_server"
#   project = var.project
#   subnet  = module.vpc.subnet
# }

# module "firewall" {
#   source  = "../../modules/firewall"
#   project = var.project
#   subnet  = module.vpc.subnet
# }
  
module "bigquery" {
  source                     = "terraform-google-modules/bigquery/google"
  version                    = "4.5.0"
  dataset_id                 = "dwh"
  dataset_name               = "dwh"
  description                = "Our main data warehouse located in the US"
  project_id                 = var.project
  location                   = "US"
  delete_contents_on_destroy = true
  tables = [
    {
      table_id           = "wikipedia_pageviews_2021",
      schema             = "schemas/pageviews_2021.schema.json",
      time_partitioning  = null,
      range_partitioning = null,
      expiration_time    = 2524604400000, # 2050/01/01
      clustering = [ "wiki", "title" ],
      labels = {
        env      = "devops"
        billable = "true"
        owner    = "joedoe"
      },
    }
  ]
  dataset_labels = {
    env      = "dev"
    billable = "true"
    owner    = "janesmith"
  }
}

resource "google_pubsub_topic" "gcs-new-file" {
  name = "gcs-new-file"
}

resource "google_pubsub_subscription" "gcs-new-file-sub" {
  name  = "gcs-new-file-sub"
  topic = google_pubsub_topic.gcs-new-file.name

  labels = {
    foo = "bq-gcs-new-file"
  }

  # 20 minutes
  message_retention_duration = "1200s"
  retain_acked_messages      = true

  ack_deadline_seconds = 20

  expiration_policy {
    ttl = "300000.5s"
  }
  retry_policy {
    minimum_backoff = "10s"
  }

  enable_message_ordering    = false
}



resource "google_storage_bucket" "bq-files-bucket" {
  name          = "bq-files-bucket"
  force_destroy = true
  location      = "US"
  #public_access_prevention = "enforced"
}

resource "google_storage_bucket_iam_binding" "member" {
  bucket = google_storage_bucket.bq-files-bucket.name
  role = "roles/storage.admin"
  members = ["allUsers", "allAuthenticatedUsers"]
}

resource "google_storage_notification" "notification" {
  bucket         = google_storage_bucket.bq-files-bucket.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.gcs-new-file.id
  event_types    = ["OBJECT_FINALIZE", "OBJECT_METADATA_UPDATE"]
  custom_attributes = {
    new-attribute = "new-attribute-value"
  }
  depends_on = [google_pubsub_topic_iam_binding.binding]
}

// Enable notifications by giving the correct IAM permission to the unique service account.

data "google_storage_project_service_account" "gcs_account" {
}

resource "google_pubsub_topic_iam_binding" "binding" {
  topic   = google_pubsub_topic.gcs-new-file.id
  role    = "roles/pubsub.publisher"
  members = ["serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"]
}

// End enabling notifications


resource "google_cloudbuild_trigger" "gcs-to-bigquery" {
  name = "gcs-to-bigquery"

  github {
    owner = "shanilevy"
    name = "gcs-to-bigquery-python"
    push {
      branch = ".*"
    }
  }
  filename = "cloudbuild.yaml"
  depends_on = [module.bigquery]
}

# resource "google_container_registry" "registry" {
#   project  = var.project
#   location = var.region
# }


resource "google_cloud_run_service" "my-service" {
  name = var.service_name
  location = var.region

  template  {
    spec {
    containers {
            image = "gcr.io/cloudrun/hello"
    }
  }
  }
  traffic {
    percent         = 100
    latest_revision = true
  }
}

# resource "google_cloud_run_service_iam_member" "allUsers" {
#   service  = google_cloud_run_service.my-service.name
#   location = google_cloud_run_service.my-service.location
#   role     = "roles/run.invoker"
#   member   = "allUsers"
# }

# resource "google_service_account" "build_runner" {
#   project      = "example"
#   account_id   = "build-runner"
# }
  
# resource "google_project_iam_custom_role" "build_runner" {
#   project     = "example"
#   role_id     = "buildRunner"
#   title       = "Build Runner"
#   description = "Grants permissions to trigger Cloud Builds."
#   permissions = ["cloudbuild.builds.create"]
# }

# resource "google_project_iam_member" "build_runner_build_runner" {
#   project = "example"
#   role    = google_project_iam_custom_role.build_runner.name
#   member  = "serviceAccount:${google_service_account.build_runner.email}"
# }

