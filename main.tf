provider "aws" {
  region = "ap-southeast-1"
}

module "networking" {
  source   = "./aws/networking"
  vpc_cidr = "10.0.0.0/16"
  azs      = ["ap-southeast-1a", "ap-southeast-1b"]
}

module "security" {
  source = "./aws/security"
  vpc_id = module.networking.vpc_id
}

module "compute" {
  source          = "./aws/compute"
  vpc_id          = module.networking.vpc_id
  public_subnets  = module.networking.public_subnets
  private_subnets = module.networking.private_subnets
  alb_sg_id       = module.security.alb_sg_id
  app_sg_id       = module.security.app_sg_id
  s3_bucket       = module.storage.bucket_id
  cdn_base_url    = "https://${module.storage.cloudfront_domain_name}"
  db_endpoint     = module.database.docdb_endpoint
  db_username     = var.db_username
  db_password     = var.db_password

  # App Secrets
  secret_key_access_token  = var.secret_key_access_token
  secret_key_refresh_token = var.secret_key_refresh_token
  stripe_secret_key        = var.stripe_secret_key
  stripe_webhook_secret    = var.stripe_webhook_secret
  email_user               = var.email_user
  email_pass               = var.email_pass
  google_client_id         = var.google_client_id
  google_client_secret     = var.google_client_secret
  gemini_api_key           = var.gemini_api_key
  resend_api               = var.resend_api
}

module "database" {
  source             = "./aws/database"
  database_subnets   = module.networking.database_subnets
  data_sg_id         = module.security.data_sg_id
  db_username        = var.db_username
  db_password        = var.db_password
}

module "storage" {
  source = "./aws/storage"
}
