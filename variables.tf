variable "proj_name" { type = string }
variable "aws_region" { type = string }
variable "vpc_cidr" { type = string }
variable "vpc_azs" { type = list(string) }

variable "db_username" { type = string }

variable "db_password" {
  type      = string
  sensitive = true
}

# ============================================================
# App Secrets
# ============================================================
variable "secret_key_access_token" {
  description = "JWT Access Token secret key"
  type        = string
  sensitive   = true
}

variable "secret_key_refresh_token" {
  description = "JWT Refresh Token secret key"
  type        = string
  sensitive   = true
}

variable "stripe_secret_key" {
  description = "Stripe API Secret Key"
  type        = string
  sensitive   = true
}

variable "stripe_webhook_secret" {
  description = "Stripe Webhook Secret"
  type        = string
  sensitive   = true
}

variable "email_user" {
  description = "Email sender address"
  type        = string
}

variable "email_pass" {
  description = "Email app password"
  type        = string
  sensitive   = true
}

variable "google_client_id" {
  description = "Google OAuth Client ID"
  type        = string
  sensitive   = true
}

variable "google_client_secret" {
  description = "Google OAuth Client Secret"
  type        = string
  sensitive   = true
}

variable "gemini_api_key" {
  description = "Google Gemini API Key"
  type        = string
  sensitive   = true
}

variable "resend_api" {
  description = "Resend API Key"
  type        = string
  sensitive   = true
}
