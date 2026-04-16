variable "vpc_id" { type = string }
variable "public_subnets" { type = list(string) }
variable "private_subnets" { type = list(string) }
variable "alb_sg_id" { type = string }
variable "app_sg_id" { type = string }

variable "s3_bucket" { type = string }
variable "cdn_base_url" { type = string }
variable "db_endpoint" { type = string }
variable "db_username" { type = string }
variable "db_password" { type = string }

# App Secrets
variable "secret_key_access_token" {
  type      = string
  sensitive = true
}

variable "secret_key_refresh_token" {
  type      = string
  sensitive = true
}

variable "stripe_secret_key" {
  type      = string
  sensitive = true
}

variable "stripe_webhook_secret" {
  type      = string
  sensitive = true
}

variable "email_user" {
  type = string
}

variable "email_pass" {
  type      = string
  sensitive = true
}

variable "google_client_id" {
  type      = string
  sensitive = true
}

variable "google_client_secret" {
  type      = string
  sensitive = true
}

variable "gemini_api_key" {
  type      = string
  sensitive = true
}

variable "resend_api" {
  type      = string
  sensitive = true
}
