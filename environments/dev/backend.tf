terraform {
 backend "gcs" {
   bucket  = "dataops-terraform-example-tfstate"
   prefix  = "terraform/state"
 }
}
