terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12"
    }
  }

  # State lives in a GCS bucket; values come from backend.hcl (git-ignored).
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
}
