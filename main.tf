# terraform {
#   backend "s3" {
#     bucket         = "xrestaurant-tfstate"
#     key            = "terraform.state"
#     region         = "ap-southeast-1"
#     dynamodb_table = "xrestaurant-tfstate-lock"
#   }
# }

provider "aws" {
  region = var.aws_region
}

module "networking" {
  source     = "./tf/networking"
  proj_name  = var.proj_name
  aws_region = var.aws_region
}

module "security" {
  source    = "./tf/security"
  proj_name = var.proj_name
  vpc_id    = module.networking.vpc_id
}

module "compute" {
  source          = "./tf/compute"
  proj_name       = var.proj_name
  vpc_region      = var.aws_region
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
  source           = "./tf/database"
  proj_name        = var.proj_name
  database_subnets = module.networking.database_subnets
  data_sg_id       = module.security.data_sg_id
  db_username      = var.db_username
  db_password      = var.db_password
}

module "storage" {
  source    = "./tf/storage"
  proj_name = var.proj_name
}
