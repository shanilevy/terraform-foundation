terraform {
 backend "gcs" {
   bucket  = "dataops-terraform-tfstate"
   prefix  = "terraform/state"
 }
}
