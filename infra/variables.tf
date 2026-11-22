variable "project_id" {
  description = "Google Cloud project ID"
  type        = string
}

variable "region" {
  description = "Region for all regional resources"
  type        = string
  default     = "asia-southeast1"
}

variable "app_subnet_cidr" {
  description = "Private subnet for the API instances (week 1)"
  type        = string
  default     = "10.10.0.0/24"
}
