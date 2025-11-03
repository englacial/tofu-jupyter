# Tofu JupyterHub - Main OpenTofu Configuration
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "registry.opentofu.org/hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "registry.opentofu.org/hashicorp/kubernetes"
      version = "~> 2.24"
    }
    helm = {
      source  = "registry.opentofu.org/hashicorp/helm"
      version = "~> 2.12"
    }
    random = {
      source  = "registry.opentofu.org/hashicorp/random"
      version = "~> 3.6"
    }
    sops = {
      source  = "registry.opentofu.org/carlpett/sops"
      version = "~> 1.0"
    }
  }

  # Backend configuration loaded from backend.tfvars
  # OpenTofu supports native state encryption configured in encryption.tf
  backend "s3" {}
}

# Import native encryption configuration for OpenTofu
# This provides state, plan, and output encryption using AWS KMS
# See encryption.tf for detailed configuration

# Provider Configuration
provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}

provider "sops" {}

# Load encrypted secrets
data "sops_file" "secrets" {
  source_file = "${path.module}/environments/${var.environment}/secrets.yaml"
}

# Local variables
locals {
  common_tags = {
    Environment = var.environment
    Application = "jupyterhub"
    Terraform   = "true"
    Owner       = var.owner_email
    CostCenter  = var.cost_center
  }

  cluster_name = "${var.cluster_name}-${var.environment}"

  # Extract secrets
  cognito_client_secret = data.sops_file.secrets.data["cognito.client_secret"]
  github_token         = try(data.sops_file.secrets.data["github.token"], "")

  # Cost optimization flags
  enable_nat_gateway = var.enable_nat_gateway
  enable_spot_instances = var.enable_spot_instances

  # Node group configuration
  main_node_config = {
    min_size     = var.scale_to_zero ? 0 : var.main_node_min_size
    desired_size = var.scale_to_zero ? 0 : var.main_node_desired_size
    max_size     = var.main_node_max_size
  }

  dask_node_config = {
    min_size     = var.scale_to_zero ? 0 : var.dask_node_min_size
    desired_size = var.scale_to_zero ? 0 : var.dask_node_desired_size
    max_size     = var.dask_node_max_size
  }
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

# Module: Networking
module "networking" {
  source = "./modules/networking"

  cluster_name       = local.cluster_name
  region            = var.region
  availability_zones = data.aws_availability_zones.available.names
  vpc_cidr          = var.vpc_cidr
  enable_nat_gateway = local.enable_nat_gateway
  single_nat_gateway = var.single_nat_gateway
  tags              = local.common_tags
}

# Module: KMS
module "kms" {
  source = "./modules/kms"

  cluster_name = local.cluster_name
  environment  = var.environment
  tags        = local.common_tags
}

# Module: Cognito
module "cognito" {
  source = "./modules/cognito"

  cluster_name = local.cluster_name
  domain_name  = var.domain_name
  environment  = var.environment
  admin_email  = var.admin_email
  tags        = local.common_tags
}

# Module: S3
module "s3" {
  source = "./modules/s3"

  cluster_name    = local.cluster_name
  environment     = var.environment
  force_destroy   = var.force_destroy_s3
  lifecycle_days  = var.s3_lifecycle_days
  tags           = local.common_tags
}

# Module: ACM Certificate
module "acm" {
  source = "./modules/acm"

  domain_name = var.domain_name
  tags       = local.common_tags
}

# Module: EKS
module "eks" {
  source = "./modules/eks"

  cluster_name     = local.cluster_name
  cluster_version  = var.kubernetes_version
  region          = var.region
  vpc_id          = module.networking.vpc_id
  subnet_ids      = module.networking.private_subnet_ids
  kms_key_id      = module.kms.key_id

  # Node groups
  main_node_instance_types = var.main_node_instance_types
  main_node_min_size       = local.main_node_config.min_size
  main_node_desired_size   = local.main_node_config.desired_size
  main_node_max_size       = local.main_node_config.max_size

  dask_node_instance_types = var.dask_node_instance_types
  dask_node_min_size       = local.dask_node_config.min_size
  dask_node_desired_size   = local.dask_node_config.desired_size
  dask_node_max_size       = local.dask_node_config.max_size

  enable_spot_instances = local.enable_spot_instances

  tags = local.common_tags

  depends_on = [module.networking]
}

# Module: Kubernetes Resources
module "kubernetes" {
  source = "./modules/kubernetes"

  cluster_name = local.cluster_name
  s3_bucket    = module.s3.bucket_name
  kms_key_id   = module.kms.key_id

  depends_on = [module.eks]
}

# Module: Helm Releases
module "helm" {
  source = "./modules/helm"

  cluster_name          = local.cluster_name
  domain_name          = var.domain_name
  certificate_arn      = module.acm.certificate_arn
  s3_bucket            = module.s3.bucket_name
  cognito_client_id    = module.cognito.client_id
  cognito_client_secret = local.cognito_client_secret
  cognito_domain       = module.cognito.domain
  cognito_user_pool_id = module.cognito.user_pool_id
  admin_email          = var.admin_email

  # Resource limits
  user_cpu_guarantee    = var.user_cpu_guarantee
  user_cpu_limit       = var.user_cpu_limit
  user_memory_guarantee = var.user_memory_guarantee
  user_memory_limit    = var.user_memory_limit

  # Dask configuration
  dask_worker_cores_max  = var.dask_worker_cores_max
  dask_worker_memory_max = var.dask_worker_memory_max
  dask_cluster_max_cores = var.dask_cluster_max_cores

  # Idle timeouts
  kernel_cull_timeout = var.kernel_cull_timeout
  server_cull_timeout = var.server_cull_timeout

  depends_on = [module.kubernetes, module.cognito, module.acm]
}

# Module: Monitoring (Optional)
module "monitoring" {
  count  = var.enable_monitoring ? 1 : 0
  source = "./modules/monitoring"

  cluster_name = local.cluster_name
  region      = var.region
  tags        = local.common_tags

  depends_on = [module.eks]
}

# Module: Auto-shutdown (Optional)
module "auto_shutdown" {
  count  = var.enable_auto_shutdown ? 1 : 0
  source = "./modules/auto_shutdown"

  cluster_name      = local.cluster_name
  environment       = var.environment
  shutdown_schedule = var.shutdown_schedule
  startup_schedule  = var.startup_schedule
  tags             = local.common_tags

  depends_on = [module.eks]
}