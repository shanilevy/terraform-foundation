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

# Enable Cloud Run API
resource "google_project_service" "run" {
  project = var.project
  service            = "run.googleapis.com"
}

# Enable Cloud Build API
resource "google_project_service" "cloudbuild" {
  project = var.project
  service            = "cloudbuild.googleapis.com"
}

# Enable Eventarc API
resource "google_project_service" "eventarc" {
  project = var.project
  service            = "eventarc.googleapis.com"
}

# Enable Cloud Resource Manager API
resource "google_project_service" "cloudresourcemanager" {
  project = var.project
  service            = "cloudresourcemanager.googleapis.com"
}

# Enable Dataform API
resource "google_project_service" "dataform" {
  project = var.project
  service            = "dataform.googleapis.com"
}

resource "google_project_service" "workflows" {
  service            = "workflows.googleapis.com"
  disable_on_destroy = false
}

  
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

resource "google_pubsub_topic_iam_binding" "binding" {
    topic       = "${google_pubsub_topic.gcs-new-file.name}"
    role        = "roles/pubsub.publisher"

    members     = ["serviceAccount:service-${var.project_number}@gs-project-accounts.iam.gserviceaccount.com"]
}  

  
resource "google_storage_bucket" "bq-files-bucket" {
 name          = "bq-files-bucket"
 location      = "US"
 storage_class = "STANDARD"

 uniform_bucket_level_access = true
}

# Upload a text file as an object
# to the storage bucket

resource "google_storage_bucket_object" "default" {
 name         = "file.txt"
 source       = "file.txt"
 content_type = "text/plain"
 bucket       = google_storage_bucket.bq-files-bucket.id
}

resource "google_storage_notification" "notification" {
  bucket         = google_storage_bucket.bq-files-bucket.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.gcs-new-file.id
  event_types    = ["OBJECT_FINALIZE"]
}

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
            image = "gcr.io/${var.project}/gcs-bq-image:ff3e9ca"
    }
  }
  }
  traffic {
    percent         = 100
    latest_revision = true
  }
}

resource "google_eventarc_trigger" "trigger-pubsub-tf" {
    name = "trigger-pubsub-tf"
    location = var.region
    matching_criteria {
        attribute = "type"
        value = "google.cloud.pubsub.topic.v1.messagePublished"
    }
    destination {
        cloud_run_service {
            service = google_cloud_run_service.my-service.name
            region = var.region
        }
    }
    transport {
    pubsub {
      topic = "projects/${var.project_id}/topics/gcs-new-file"
    }
  }
}


resource "google_secret_manager_secret" "secret" {
  provider = google-beta
  secret_id = "github-dataform-secret"
  project   = var.project

  replication {
    automatic = true
  }
}

resource "google_secret_manager_secret_version" "secret_version" {
  provider = google-beta
  secret = google_secret_manager_secret.secret.id

  secret_data = var.secret_data
}

resource "google_dataform_repository" "dataform_respository" {
  provider = google-beta
  name = "dataform_gcs_to_bq_repository"
  project   = var.project
  region = var.region

  git_remote_settings {
      url = "https://github.com/shanilevy/dataform-gcs-to-bq"
      default_branch = "bq-branch"
      authentication_token_secret_version = google_secret_manager_secret_version.secret_version.id
  }
}

resource "google_dataform_repository" "dataform_respository2" {
  provider = google-beta
  name = "dataform_gcs_to_bq_repository2"
  project   = var.project
  region = var.region

  git_remote_settings {
      url = "https://github.com/shanilevy/dataform-gcs-to-bq"
      default_branch = "bq-branch"
      authentication_token_secret_version = google_secret_manager_secret_version.secret_version.id
  }
}

resource "google_service_account" "workflows_service_account" {
  account_id   = "sample-workflows-sa"
  display_name = "Sample Workflows Service Account"
}

resource "google_workflows_workflow" "workflows_example" {
  name            = "sample-workflow"
  region          = "us-central1"
  description     = "A sample workflow"
  service_account = google_service_account.workflows_service_account.id
  source_contents = <<-EOF
  # This workflow does the following:
  # - reads current time and date information from an external API and stores
  #   the response in CurrentDateTime variable
  # - retrieves a list of Wikipedia articles related to the day of the week
  #   from CurrentDateTime
  # - returns the list of articles as an output of the workflow
  # FYI, In terraform you need to escape the $$ or it will cause errors.

  main:
    steps:
    - init:
        assign:
        - repository: projects/dataops-terraform/locations/us-central1/repositories/dataform_gcs_to_bq_repository
    - createCompilationResult:
        call: http.post
        args:
            url: "https://dataform.googleapis.com/v1beta1/" + repository + "/compilationResults"
            auth:
                type: OAuth2
            body:
                gitCommitish: bq-branch
        result: compilationResult
    - createWorkflowInvocation:
        call: http.post
        args:
            url: "https://dataform.googleapis.com/v1beta1/" + repository + "/workflowInvocations"
            auth:
                type: OAuth2
            body:
                compilationResult: $${compilationResult.body.name}
        result: workflowInvocation
    - complete:
        return: $${workflowInvocation.body.name}
EOF

  depends_on = [google_project_service.workflows]
}

# resource "google_cloud_run_service_iam_member" "allUsers" {
#   service  = google_cloud_run_service.my-service.name
#   location = google_cloud_run_service.my-service.location
#   role     = "roles/run.invoker"
#   member   = "allUsers"
# }

# resource "google_service_account_iam_binding" "cloudbuild-role1" {
#   service_account_id = "${var.project_id}@cloudbuild.gserviceaccount.com"
#   role               = "roles/editor"

#   members     = ["serviceAccount:${var.project_id}@cloudbuild.iam.gserviceaccount.com"]
# }

# resource "google_service_account_iam_binding" "cloudbuild-role2" {
#   service_account_id = "${var.project_id}@cloudbuild.gserviceaccount.com"
#   role               = "roles/storage.admin"
# }

# resource "google_service_account_iam_binding" "cloudbuild-role3" {
#   service_account_id = "${var.project_id}@cloudbuild.gserviceaccount.com"
#   role               = "roles/storage.objectAdmin"
# }

# resource "google_service_account_iam_binding" "cloudbuild-role4" {
#   service_account_id = "${var.project_id}@cloudbuild.gserviceaccount.com"
#   role               = "roles/bigquery.admin
# }

# resource "google_service_account_iam_binding" "cloudstorage-role1" {
#   service_account_id = "service-${var.project_number}@gs-project-accounts.iam.gserviceaccount.com"
#   role               = "roles/pubsub.admin"
# }

# resource "google_service_account_iam_binding" "compute-role1" {
#   service_account_id = "${var.project_id}-compute@developer.gserviceaccount.com"
#   role               = "roles/storage.admin"
# }

# resource "google_service_account_iam_binding" "compute-role1" {
#   service_account_id = "${var.project_id}-compute@developer.gserviceaccount.com"
#   role               = "roles/bigquery.admin"
# }



