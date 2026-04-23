# 5XRestaurant — AWS Infrastructure Documentation

> **Terraform-managed, production-grade AWS infrastructure for the 5XRestaurant backend.**  
> Region: `ap-southeast-1` (Singapore) | Provider: `hashicorp/aws ~> 6.41`

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Project Structure](#2-project-structure)
3. [Detailed Resource / Module Analysis](#3-detailed-resource--module-analysis)
   - [3.1 Networking Module](#31-networking-module-tfnetworking)
   - [3.2 Security Module](#32-security-module-tfsecurity)
   - [3.3 Storage Module](#33-storage-module-tfstorage)
   - [3.4 Database Module](#34-database-module-tfdatabase)
   - [3.5 Compute Module](#35-compute-module-tfcompute)
4. [Risk Assessment](#4-risk-assessment)
5. [Best Practices & Recommendations](#5-best-practices--recommendations)

---

## 1. Architecture Overview

This project provisions a **containerized, serverless-compute web application** on AWS for the 5XRestaurant platform. The core pattern is a classic **3-tier architecture** (Presentation → Application → Data) enhanced with a CDN layer and a managed secrets store:

```
Internet
    │
    ├─── CloudFront CDN ──────────────────────────── S3 (Frontend SPA)
    │
    └─── API Gateway (HTTPS) ─── ALB (HTTP/80) ─── ECS Fargate (Backend API)
                                                         │
                                              ┌──────────┴──────────┐
                                         Secrets Manager       DocumentDB
                                         (API Keys)            (MongoDB)
                                              │
                                             S3 (Assets Upload)
```

### Key Technology Decisions

| Layer | Service | Rationale |
|---|---|---|
| **Frontend delivery** | S3 + CloudFront | Zero-server static asset hosting with global edge caching and HTTPS |
| **Backend compute** | ECS Fargate | Serverless containers — no EC2 fleet to manage; scales on demand |
| **Backend entrypoint** | API Gateway v2 (HTTP) | Provides a stable HTTPS public URL, proxies to ALB; decouples DNS from infra |
| **Load balancing** | ALB | L7 routing with health-check awareness; required by Fargate `awsvpc` networking |
| **Database** | Amazon DocumentDB | MongoDB-compatible managed database with built-in TLS, automated backups, 3-AZ storage replication |
| **Secrets** | AWS Secrets Manager | API keys injected at container runtime; never baked into images or .env files |
| **Container registry** | Amazon ECR | Private image registry with vulnerability scanning on push |
| **Networking** | VPC with public / private / database subnet tiers | Strict network segmentation; Fargate tasks never have a public IP |
| **Egress** | Single NAT Gateway | Cost-effective internet egress for private subnet resources |
| **S3 egress** | VPC Gateway Endpoint | S3 traffic from private subnets never leaves the AWS backbone |

---

## 2. Project Structure

```
demo_aws/
├── main.tf                  # Root module — provider config + module orchestration
├── variables.tf             # Root-level input variable declarations
├── outputs.tf               # Root-level outputs (ALB URL, CloudFront URL, ECR URL…)
├── terraform.tfvars         # ⚠️ Populated secret values — must NOT be committed to VCS
├── .terraform.lock.hcl      # Provider version lock file (commit this)
├── push_docker.sh           # Helper script: build & push Docker image to ECR
│
└── tf/                      # Child modules (one per infrastructure concern)
    ├── networking/          # VPC, subnets, NAT Gateway, S3 VPC Endpoint
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── security/            # Security Groups (ALB, App, Data tiers)
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── storage/             # S3 buckets, CloudFront distribution, OAC, bucket policies
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── database/            # DocumentDB cluster + subnet group
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── compute/             # ECR, ECS (cluster/task/service), ALB, IAM roles,
        ├── main.tf          # API Gateway, Secrets Manager
        ├── variables.tf
        └── outputs.tf
```

### File Roles

| File | Role |
|---|---|
| `main.tf` (root) | Declares the `aws` provider and calls all child modules in dependency order |
| `variables.tf` (root) | Centralizes all inputs: project name, region, DB credentials, and all sensitive API key variables |
| `outputs.tf` (root) | Surfaces the key URLs (ALB, CloudFront, API Gateway, ECR) after `terraform apply` |
| `terraform.tfvars` | Supplies concrete values for sensitive variables — **should be in `.gitignore`** |
| `.terraform.lock.hcl` | Pins exact provider checksums for reproducible plans — **must be committed** |
| `push_docker.sh` | Automates ECR login → Docker build → tag → push workflow |

---

## 3. Detailed Resource / Module Analysis

### 3.1 Networking Module (`tf/networking`)

**Purpose:** Provision the foundational VPC with isolated subnet tiers, internet/NAT egress, and a private S3 access path.

#### `module.vpc` (terraform-aws-modules/vpc/aws v5.0.0)

| Attribute | Value | Purpose |
|---|---|---|
| `cidr` | `10.0.0.0/16` | Large address space (65 536 IPs) for room to grow |
| `public_subnets` | `10.0.1.0/24`, `10.0.2.0/24` | Houses the ALB and NAT Gateway; directly internet-routable |
| `private_subnets` | `10.0.11.0/24`, `10.0.12.0/24` | Houses ECS Fargate tasks; no public IP, egress via NAT |
| `database_subnets` | `10.0.21.0/24`, `10.0.22.0/24` | Isolated tier for DocumentDB; no direct egress |
| `azs` | `ap-southeast-1a`, `ap-southeast-1b` | Spans 2 AZs for high availability of subnets |
| `enable_nat_gateway` | `true` | Allows private subnet resources to reach the internet (pulling images, calling APIs) |
| `single_nat_gateway` | `true` | **Cost trade-off**: one shared NAT GW instead of one per AZ; saves ~$32/mo at a SPOF risk |
| `one_nat_gateway_per_az` | `false` | Confirms single NAT GW strategy |
| `enable_dns_hostnames` | `true` | Required for VPC endpoints and ECR image pulls |
| `enable_dns_support` | `true` | Required for DNS resolution within the VPC |

**Design Rationale:** The 3-tier subnet model enforces network segmentation. Public resources (ALB) live in public subnets; application workloads (Fargate) in private; database instances in a further-isolated database-only tier. The community VPC module handles all route table wiring automatically.

#### `aws_vpc_endpoint.vpc_endpoint_s3`

| Attribute | Value | Purpose |
|---|---|---|
| `service_name` | `com.amazonaws.ap-southeast-1.s3` | AWS S3 Gateway endpoint for Singapore |
| `vpc_endpoint_type` | `Gateway` | Free-of-charge; modifies route tables rather than allocating ENIs |
| `route_table_ids` | Private route tables | Ensures ECS → S3 traffic stays within the AWS backbone, reducing NAT cost and latency |

---

### 3.2 Security Module (`tf/security`)

**Purpose:** Define the Security Group firewall rules implementing least-privilege network access at each tier.

#### `aws_security_group.alb_sg` — Internet-facing ALB

| Rule | Direction | Port | Source | Purpose |
|---|---|---|---|---|
| Ingress | In | 80/tcp | `0.0.0.0/0` | Public HTTP access from any internet client |
| Egress | Out | All | `0.0.0.0/0` | ALB forwards requests to the app tier |

#### `aws_security_group.app_sg` — ECS Fargate Tasks

| Rule | Direction | Port | Source | Purpose |
|---|---|---|---|---|
| Ingress | In | 8080/tcp | `alb_sg` (SG reference) | **Only accepts traffic from the ALB** — tasks are never directly internet-accessible |
| Egress | Out | All | `0.0.0.0/0` | Outbound for NAT (ECR pull, Secrets Manager, external APIs) |

#### `aws_security_group.data_sg` — DocumentDB

| Rule | Direction | Port | Source | Purpose |
|---|---|---|---|---|
| Ingress | In | 27017/tcp | `app_sg` (SG reference) | **Only the app tier can reach the database** — strict data-tier isolation |
| Egress | Out | All | `0.0.0.0/0` | Standard egress (typically unused at the DB tier) |

**Design Rationale:** SG chaining (`security_groups` references instead of CIDR blocks) is the correct AWS pattern for inter-tier communication. This means the rule automatically tracks instance lifecycle — if a new Fargate task starts with a new IP, it is still covered by the SG membership rule.

---

### 3.3 Storage Module (`tf/storage`)

**Purpose:** Host static frontend assets with CloudFront CDN delivery (production) and a separate public-access dev bucket.

#### `aws_s3_bucket.s3_assets` — Production Assets Bucket

| Attribute | Value | Purpose |
|---|---|---|
| `bucket_prefix` | `{proj_name}-assets-` | Unique suffix auto-appended; avoids global S3 name collision |

#### `aws_s3_bucket_public_access_block.public_access`

| Attribute | Value | Purpose |
|---|---|---|
| All four `block_*` / `restrict_*` | `true` | Completely prevents any public ACL or public bucket policy; enforces private-by-default |

#### `aws_cloudfront_origin_access_control.oac`

| Attribute | Value | Purpose |
|---|---|---|
| `signing_behavior` | `always` | CloudFront always signs requests to S3 with SigV4 |
| `signing_protocol` | `sigv4` | Modern AWS request signing; OAC replaces the legacy Origin Access Identity |

#### `aws_cloudfront_distribution.s3_distribution`

| Attribute | Value | Purpose |
|---|---|---|
| `viewer_protocol_policy` | `redirect-to-https` | Forces all viewers to HTTPS; HTTP requests auto-redirect |
| `default_root_object` | `index.html` | SPA entry point; CloudFront serves this for `/` |
| `default_ttl` / `max_ttl` | 3600 / 86400 | Assets cached at edge for 1 h by default, up to 24 h |
| `is_ipv6_enabled` | `true` | Modern dual-stack support |
| `geo_restriction` | `none` | Global delivery; no geographic blocking |
| `cloudfront_default_certificate` | `true` | Uses the AWS-provided `*.cloudfront.net` certificate (no ACM setup required) |

#### `aws_s3_bucket_policy.assets_policy`

The bucket policy restricts `s3:GetObject` exclusively to the CloudFront distribution via `AWS:SourceArn` condition. This means:  
- S3 URLs are **never directly accessible** — all access flows through CloudFront.
- Uses the modern OAC pattern (not legacy OAI).

#### `aws_s3_object.frontend_assets`

| Attribute | Value | Purpose |
|---|---|---|
| `for_each` | `fileset(…, "**/*")` | Iterates every file in the built frontend dist directory |
| `etag` | `filemd5(…)` | Enables Terraform to detect file content changes and re-upload only changed assets |
| `content_type` | Lookup map | Sets correct MIME types so browsers parse HTML/CSS/JS correctly |

#### `aws_s3_bucket.dev_assets` — Development Bucket

| Attribute | Value | Purpose |
|---|---|---|
| All `block_*` | `false` | Intentionally public — for rapid local development testing without CloudFront overhead |
| Bucket policy | `Principal: "*"`, `s3:GetObject` | Grants anonymous read access to all objects |

---

### 3.4 Database Module (`tf/database`)

**Purpose:** Provision a managed MongoDB-compatible DocumentDB cluster inside the isolated database subnet tier.

#### `aws_docdb_cluster.mongodb`

| Attribute | Value | Purpose |
|---|---|---|
| `engine` | `docdb` | Amazon DocumentDB (MongoDB-compatible) |
| `storage_encrypted` | `true` | AES-256 encryption at rest using the default AWS-managed key |
| `master_username` / `master_password` | From variables | Credentials injected at provision time; not baked into code |
| `db_subnet_group_name` | `docdb_subnet_group` | Places the cluster in the isolated database subnets |
| `vpc_security_group_ids` | `[data_sg_id]` | Only the app-tier SG can connect on port 27017 |
| `skip_final_snapshot` | `true` | ⚠️ Allows `terraform destroy` without a final backup snapshot |
| `kms_key_id` | Commented out | TODO marker for customer-managed KMS key in production |

#### `aws_docdb_cluster_instance.mongodb_instance`

| Attribute | Value | Purpose |
|---|---|---|
| `count` | `1` | **Single instance** — acknowledged cost trade-off for class/demo use; storage is still 3-AZ replicated |
| `instance_class` | `db.t3.medium` | Smallest standard instance class; adequate for low-throughput dev workloads |

**Design Rationale:** The cluster endpoint is passed to the Compute module and stored in Secrets Manager as part of the `MONGODB_URL` connection string. TLS is enforced at the connection string level (`tls=true&tlsCAFile=…`). The single-instance design accepts the compute SPOF risk explicitly, as noted in the code comment.

---

### 3.5 Compute Module (`tf/compute`)

**Purpose:** The most complex module — provisions the container registry, container runtime, load balancer, IAM identities, API Gateway proxy, and secrets store.

#### `aws_ecr_repository.backend`

| Attribute | Value | Purpose |
|---|---|---|
| `image_tag_mutability` | `MUTABLE` | Allows overwriting the `latest` tag on each deploy |
| `scan_on_push` | `true` | Automatically scans images for known CVEs on every push |
| `force_delete` | `true` | Allows `terraform destroy` to delete the repo even if images exist |

#### `aws_ecs_cluster.main`

A standard ECS cluster namespace. No capacity providers are explicitly configured → defaults to Fargate.

#### `aws_cloudwatch_log_group.ecs_logs`

| Attribute | Value | Purpose |
|---|---|---|
| `retention_in_days` | `7` | Keeps 7 days of container stdout/stderr; balances cost vs. debugging window |

#### IAM — Dual-Role Model

Two distinct IAM roles enforce the **principle of least privilege**:

| Role | Used By | Permissions |
|---|---|---|
| `ecs_task_execution_role` | ECS control plane | Pull ECR images, write CloudWatch Logs, **read Secrets Manager** (inline policy) |
| `app_role` (Task Role) | Running container process | S3 CRUD on the assets bucket, SSM Session Manager for `exec` access |

The separation is critical:
- The **execution role** is a "plumbing" role — ECS uses it behind the scenes.
- The **task role** is what the application code itself assumes via instance metadata. Granting only S3 access here means a compromised container cannot access Secrets Manager directly.

#### `aws_lb.main` — Application Load Balancer

| Attribute | Value | Purpose |
|---|---|---|
| `internal` | `false` | Internet-facing; has a public DNS name |
| `load_balancer_type` | `application` | L7 HTTP/HTTPS load balancer |
| `subnets` | Public subnets | ALB nodes live in public subnets to accept inbound internet traffic |
| `security_groups` | `[alb_sg_id]` | Only allows port 80 inbound |

#### `aws_lb_target_group.app_tg`

| Attribute | Value | Purpose |
|---|---|---|
| `target_type` | `ip` | **Required for Fargate** — targets are ENI IPs, not instance IDs |
| `port` | `8080` | Matches the container's exposed port |
| `health_check.path` | `/health` | Dedicated health endpoint; unhealthy tasks are drained |
| `unhealthy_threshold` | `10` | High tolerance before marking unhealthy — helps slow-starting containers |

#### `aws_lb_listener.front_end`

HTTP-only listener on port 80. All traffic is proxied to the target group. **No HTTPS listener is configured** — HTTPS termination is handled at API Gateway.

#### `aws_ecs_task_definition.backend`

| Attribute | Value | Purpose |
|---|---|---|
| `network_mode` | `awsvpc` | Each task gets its own ENI — required for Fargate, enables SG enforcement at task level |
| `requires_compatibilities` | `["FARGATE"]` | Locks the task to serverless compute |
| `cpu` / `memory` | `256` / `512` | 0.25 vCPU / 512 MB — minimal allocation; appropriate for low-traffic demo |
| `execution_role_arn` | `ecs_task_execution_role` | Used by ECS to pull image and inject secrets |
| `task_role_arn` | `app_role` | Assumed by the running container for S3 and SSM access |
| `secrets` | Secrets Manager ARN references | **Secrets are never exposed as env vars at rest** — injected at runtime by ECS |
| `environment` | Non-sensitive values only | PORT, region, bucket name, CDN URL |
| `logConfiguration` | `awslogs` driver | Container logs → CloudWatch Logs |

#### `aws_ecs_service.backend_service`

| Attribute | Value | Purpose |
|---|---|---|
| `desired_count` | `2` | Two running tasks across AZs for basic high availability |
| `launch_type` | `FARGATE` | Serverless; no EC2 instances to manage |
| `assign_public_ip` | `false` | Tasks are in private subnets; access the internet via NAT |
| `enable_execute_command` | `true` | Allows `aws ecs execute-command` for live debugging |
| `depends_on` | `[aws_lb_listener.front_end]` | Prevents tasks from registering before ALB listener is ready |

#### API Gateway v2

| Resource | Key Attribute | Purpose |
|---|---|---|
| `aws_apigatewayv2_api` | `protocol_type = "HTTP"` | HTTP API (v2); cheaper and lower-latency than REST API (v1) |
| `aws_apigatewayv2_integration` | `integration_type = "HTTP_PROXY"` | Forwards all requests to ALB as-is; transparent proxy |
| `aws_apigatewayv2_route` | `route_key = "ANY /{proxy+}"` | Catch-all route; all paths and methods forwarded |
| `aws_apigatewayv2_stage` | `name = "$default"`, `auto_deploy = true` | Default stage auto-deploys on any route/integration change |

**Design Rationale:** API Gateway provides a stable HTTPS endpoint (`execute-api.amazonaws.com`) without requiring ACM certificate provisioning. The `HTTP_PROXY` integration adds minimal overhead (~1 ms). The trade-off is that all traffic passes through both APIGW and ALB, adding cost for high-volume scenarios.

#### `aws_secretsmanager_secret.backend_secrets`

| Attribute | Value | Purpose |
|---|---|---|
| `name_prefix` | `{proj_name}-backend-keys-` | Unique suffix per Terraform workspace; allows destroy/recreate cycles |
| `recovery_window_in_days` | `0` | ⚠️ Immediate deletion on destroy; **not production-safe** |

#### `aws_secretsmanager_secret_version.backend_secrets_values`

All secrets are stored as a single JSON object. ECS extracts individual keys via the `valueFrom` syntax (`arn:…:KEY::`). The MongoDB connection string is dynamically constructed from `db_username`, `db_password`, and `db_endpoint` at Terraform apply time.

---

## 4. Risk Assessment

### 4.1 Security Risks

| Severity | Issue | Location | Details |
|---|---|---|---|
| 🔴 **Critical** | Secrets committed to VCS in `terraform.tfvars` | `/terraform.tfvars` | Live Stripe keys, Google OAuth secrets, Gemini API key, and email passwords are checked into the repository. GitHub Secret Scanning will flag these; they may already be exposed. |
| 🔴 **Critical** | Database password hardcoded as a default value | `variables.tf` L23 | `db_password` has `default = "SuperSecretPass123"`. Any `terraform apply` without an explicit override will use this value. |
| 🟠 **High** | ALB serves traffic over plain HTTP (no HTTPS) | `compute/main.tf` L138–147 | The ALB listener is HTTP/80 only. Traffic between the user and API Gateway is HTTPS, but direct ALB URL (`alb_public_url` output) is unencrypted and publicly accessible, bypassing API Gateway altogether. |
| 🟠 **High** | Dev S3 bucket is entirely public | `storage/main.tf` L116–142 | `dev_assets` bucket has all public access blocks disabled and a `Principal: "*"` bucket policy. If sensitive files are uploaded here, they are publicly readable. |
| 🟠 **High** | `recovery_window_in_days = 0` on Secrets Manager | `compute/main.tf` L263 | Secrets are permanently deleted instantly on `terraform destroy`. In a shared environment, this could accidentally destroy production secrets. |
| 🟡 **Medium** | No custom KMS key for DocumentDB encryption | `database/main.tf` L10 | `storage_encrypted = true` uses the AWS-managed default key. The production TODO comment acknowledges this. Without a CMK, you cannot control key rotation, audit key usage granularly, or revoke access. |
| 🟡 **Medium** | CloudFront uses default `*.cloudfront.net` certificate | `storage/main.tf` L57–59 | No custom domain or ACM certificate. The CDN URL is not branded and may not meet production SLA requirements. |
| 🟡 **Medium** | SSM `ssmmessages:*` on `Resource: "*"` | `compute/main.tf` L100–107 | The task role allows SSM channel creation on all resources. This is the standard pattern for ECS Exec, but should be documented and scoped if possible. |
| 🟢 **Low** | `image_tag_mutability = MUTABLE` on ECR | `compute/main.tf` L3 | Mutable tags allow overwriting `latest`; no rollback trail. Immutable tags (`IMMUTABLE`) + versioned tags provide a safer deployment model. |
| 🟢 **Low** | No ECR lifecycle policy | `compute/main.tf` | Untagged or old images accumulate indefinitely, increasing storage costs. |

### 4.2 Operational Risks

| Severity | Issue | Location | Details |
|---|---|---|---|
| 🔴 **Critical** | Remote state backend is disabled | `main.tf` L1–8 | The `backend "s3"` block is commented out. State is stored locally in `terraform.tfstate`. This file is committed to the repo (seen in directory listing), meaning state — which may contain sensitive data — is in version control. **Team collaboration and CI/CD are impossible without a remote backend.** |
| 🟠 **High** | `skip_final_snapshot = true` on DocumentDB | `database/main.tf` L15 | `terraform destroy` will permanently delete the cluster and all data without any point-in-time backup. No recovery is possible. |
| 🟠 **High** | `force_delete = true` on ECR repository | `compute/main.tf` L4 | All container images are deleted without confirmation on `terraform destroy`. |
| 🟡 **Medium** | Single NAT Gateway (SPOF) | `networking/main.tf` L14 | `single_nat_gateway = true` saves cost but means that if the NAT Gateway's AZ (`ap-southeast-1a`) has an outage, all private-subnet resources lose internet connectivity. |
| 🟡 **Medium** | Single DocumentDB instance (SPOF) | `database/main.tf` L21 | `count = 1` acknowledged in code comment. A single compute node means any instance failure causes database downtime until AWS replaces it (typically minutes). |
| 🟡 **Medium** | Frontend assets uploaded via `aws_s3_object` | `storage/main.tf` L88–107 | Using Terraform to manage individual S3 objects is fragile. Large dist directories slow down `terraform plan` significantly. A `null_resource` + AWS CLI sync, or a CI/CD pipeline step, is more appropriate. Moreover, no CloudFront cache invalidation is triggered after uploads, so clients may see stale assets. |
| 🟡 **Medium** | No auto-scaling policy on ECS service | `compute/main.tf` | `desired_count = 2` is fixed. Under load spikes, the service cannot scale out. There is no `aws_appautoscaling_target` or `aws_appautoscaling_policy` defined. |
| 🟡 **Medium** | Hardcoded AWS region in container environment | `compute/main.tf` L176, L198 | `"ap-southeast-1"` appears as a string literal in the task definition JSON rather than referencing `var.aws_region`. Breaks multi-region deployments. |
| 🟢 **Low** | `terraform.tfstate` and `terraform.tfstate.backup` in the repo | Root | State files contain resource IDs and potentially sensitive data in plaintext. They must be excluded from VCS. |

### 4.3 Cost Optimization Risks

| Area | Issue | Estimated Impact |
|---|---|---|
| **NAT Gateway** | Single NAT GW processes all egress from private subnets. Per-GB data processing charges add up quickly if ECS tasks make frequent external API calls or download large payloads. | ~$45/mo base + $0.045/GB processed |
| **DocumentDB** | `db.t3.medium` runs 24/7 even if idle. No automatic pause/stop is available for DocumentDB. | ~$60–70/mo for a single instance |
| **API Gateway + ALB** | Double hop (APIGW → ALB) means you pay for both ALB LCU hours and API Gateway request charges. For high-traffic APIs, this is significant. | Variable; APIGW adds ~$3.50/million requests |
| **CloudWatch Logs** | 7-day retention is reasonable, but no log metric filters or alarms are defined. External log aggregation tools (e.g., Grafana + Loki) could reduce CloudWatch costs. | Minor at demo scale |
| **ECS Fargate tasks** | `desired_count = 2` with no scale-in policy means 2 tasks run 24/7 even during quiet periods. | ~$15–20/mo for 0.25 vCPU / 512 MiB × 2 |
| **S3 + CloudFront** | Using default CloudFront certificate with no price class restriction means global edge delivery (highest tier). `PriceClass_100` (US, Canada, Europe) or `PriceClass_200` would reduce cost. | Minor at demo scale |

---

## 5. Best Practices & Recommendations

### 5.1 🔐 Eliminate Secrets from Version Control (Critical — Immediate Action Required)

**Problem:** `terraform.tfvars` containing live API keys is likely committed to the repository.

**Solution — Use a secrets manager or environment variables as input:**

```bash
# Option A: Set secrets as TF_VAR_ environment variables (CI/CD friendly)
export TF_VAR_stripe_secret_key="sk_live_..."
export TF_VAR_db_password="$(aws secretsmanager get-secret-value ...)"
terraform apply

# Option B: Use a .tfvars file that is git-ignored
echo "terraform.tfvars" >> .gitignore
```

Add to `.gitignore`:
```gitignore
terraform.tfvars
*.tfstate
*.tfstate.backup
.terraform/
```

Rotate all exposed credentials immediately (Stripe, Google, Gemini, Resend, email).

---

### 5.2 🗄️ Enable S3 Remote Backend with State Locking (Critical)

Uncomment and configure the remote backend in `main.tf`. First create the backend resources:

```hcl
# bootstrap/main.tf — run once manually before the main workspace
resource "aws_s3_bucket" "tfstate" {
  bucket = "xrestaurant-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
  }
}

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "xrestaurant-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute { name = "LockID"; type = "S" }
}
```

Then restore the backend block in `main.tf`:

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 6.0" }
  }
  backend "s3" {
    bucket         = "xrestaurant-tfstate-<account-id>"
    key            = "prod/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "xrestaurant-tfstate-lock"
    encrypt        = true
  }
}
```

---

### 5.3 🏥 Add HTTPS to the ALB (High Priority)

Replace the HTTP listener with HTTPS and add HTTP→HTTPS redirect:

```hcl
resource "aws_acm_certificate" "api" {
  domain_name       = "api.xrestaurant.com"
  validation_method = "DNS"
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.api.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
```

---

### 5.4 🔒 Remove the Dev Bucket or Harden It

The public dev bucket should not exist in a shared infrastructure repository. Recommended approaches:

**Option A — Completely remove it** from the storage module and use the production CloudFront URL for all environments.  
**Option B — Gate it with a variable:**

```hcl
variable "enable_dev_bucket" {
  type    = bool
  default = false
}

resource "aws_s3_bucket" "dev_assets" {
  count         = var.enable_dev_bucket ? 1 : 0
  bucket_prefix = "${var.proj_name}-dev-assets-"
}
```

---

### 5.5 🔁 Add ECS Auto-Scaling

```hcl
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 10
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.backend_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_cpu" {
  name               = "${var.proj_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 70.0
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
```

---

### 5.6 📦 Manage Frontend Assets Outside Terraform

Replace `aws_s3_object` with a CI/CD deploy step to avoid slow `terraform plan` on large `dist/` directories and to trigger proper CloudFront invalidations:

```bash
# In your CI/CD pipeline (GitHub Actions, etc.)
aws s3 sync ./client/dist s3://$BUCKET_ID --delete --cache-control "max-age=31536000,public"
aws s3 cp ./client/dist/index.html s3://$BUCKET_ID/index.html --cache-control "no-cache"
aws cloudfront create-invalidation --distribution-id $CF_DISTRIBUTION_ID --paths "/*"
```

---

### 5.7 📏 Make Resources DRY with Local Variables

Multiple resources repeat the same pattern. Extract common values into `locals`:

```hcl
# In root main.tf or a shared locals.tf
locals {
  common_tags = {
    Project     = var.proj_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
  aws_region = "ap-southeast-1"
}
```

Apply `tags = local.common_tags` to every resource for consistent billing attribution.

---

### 5.8 🛡️ Fix the Database Default Password

Remove the `default` value from `db_password` to force an explicit value:

```hcl
# variables.tf
variable "db_password" {
  description = "DocumentDB master password — must be supplied explicitly, never use a default"
  type        = string
  sensitive   = true
  # NO default value — Terraform will require this to be provided
  validation {
    condition     = length(var.db_password) >= 16
    error_message = "Database password must be at least 16 characters."
  }
}
```

---

### 5.9 🪵 Add Monitoring & Alerting

No CloudWatch alarms are currently defined. At minimum, add:

```hcl
resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${var.proj_name}-ecs-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ECS CPU utilization above 80%"
  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.backend_service.name
  }
}
```

---

### 5.10 🔐 Use a Customer-Managed KMS Key for DocumentDB

```hcl
resource "aws_kms_key" "docdb" {
  description             = "CMK for ${var.proj_name} DocumentDB encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

# Then in the docdb cluster:
resource "aws_docdb_cluster" "mongodb" {
  # ...
  kms_key_id       = aws_kms_key.docdb.arn
  storage_encrypted = true
}
```

---

### 5.11 🏗️ Add `terraform.tfvars.example`

Provide a template for teams without exposing real values:

```hcl
# terraform.tfvars.example — commit this file; copy to terraform.tfvars locally
proj_name = "xrestaurant"
aws_region = "ap-southeast-1"

db_password = "REPLACE_ME_minimum_16_chars"

secret_key_access_token  = "REPLACE_ME"
secret_key_refresh_token = "REPLACE_ME"
stripe_secret_key        = "sk_test_REPLACE_ME"
stripe_webhook_secret    = "whsec_REPLACE_ME"
email_user               = "your-email@example.com"
email_pass               = "REPLACE_ME"
google_client_id         = "REPLACE_ME.apps.googleusercontent.com"
google_client_secret     = "REPLACE_ME"
gemini_api_key           = "REPLACE_ME"
resend_api               = "re_REPLACE_ME"
```

---

## Quick Reference — Deployment Commands

```bash
# 1. Initialize (download providers & modules)
terraform init

# 2. Validate configuration
terraform validate

# 3. Preview changes
terraform plan -out=tfplan

# 4. Apply
terraform apply tfplan

# 5. Push Docker image to ECR after apply
bash push_docker.sh

# 6. Destroy (⚠️ destroys ALL resources including database data)
terraform destroy
```

## Outputs After Apply

| Output | Description |
|---|---|
| `alb_public_url` | Internal ALB HTTP URL (use API Gateway URL instead) |
| `cloudfront_cdn_url` | HTTPS CloudFront URL serving the React SPA |
| `ecr_repository_url` | ECR URL for pushing Docker images |
| `eatease_dev_s3_bucket` | Dev S3 bucket name for local development |
| `api_gateway_https_url` | **Primary backend API URL** — stable HTTPS endpoint |

---

*Generated by Antigravity AI — last updated April 2026.*
