# Terra JupyterHub - Variable Definitions

# Core Configuration
variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "Base name for the EKS cluster"
  type        = string
  default     = "jupyterhub"
}

variable "domain_name" {
  description = "Domain name for JupyterHub access"
  type        = string
}

variable "admin_email" {
  description = "Admin email for JupyterHub"
  type        = string
}

variable "owner_email" {
  description = "Owner email for tagging"
  type        = string
}

variable "cost_center" {
  description = "Cost center for tagging"
  type        = string
  default     = "engineering"
}

# Kubernetes Configuration
variable "kubernetes_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.29"
}

# Network Configuration
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway for private subnets (costs ~$45/month)"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway to save costs"
  type        = bool
  default     = true
}

# Node Group Configuration - Main
variable "main_node_instance_types" {
  description = "Instance types for main node group"
  type        = list(string)
  default     = ["r5.xlarge"]
}

variable "main_node_min_size" {
  description = "Minimum number of main nodes"
  type        = number
  default     = 1
}

variable "main_node_desired_size" {
  description = "Desired number of main nodes"
  type        = number
  default     = 1
}

variable "main_node_max_size" {
  description = "Maximum number of main nodes"
  type        = number
  default     = 5
}

# Node Group Configuration - Dask Workers
variable "dask_node_instance_types" {
  description = "Instance types for Dask worker nodes"
  type        = list(string)
  default     = ["m5.large", "m5.xlarge", "m5.2xlarge"]
}

variable "dask_node_min_size" {
  description = "Minimum number of Dask nodes"
  type        = number
  default     = 0  # Scale to zero!
}

variable "dask_node_desired_size" {
  description = "Desired number of Dask nodes"
  type        = number
  default     = 0
}

variable "dask_node_max_size" {
  description = "Maximum number of Dask nodes"
  type        = number
  default     = 30
}

variable "enable_spot_instances" {
  description = "Use spot instances for Dask workers"
  type        = bool
  default     = true
}

# User Resource Limits
variable "user_cpu_guarantee" {
  description = "CPU cores guaranteed per user"
  type        = number
  default     = 2
}

variable "user_cpu_limit" {
  description = "Maximum CPU cores per user"
  type        = number
  default     = 4
}

variable "user_memory_guarantee" {
  description = "Memory guaranteed per user (GB)"
  type        = string
  default     = "15G"
}

variable "user_memory_limit" {
  description = "Maximum memory per user (GB)"
  type        = string
  default     = "30G"
}

# Dask Configuration
variable "dask_worker_cores_max" {
  description = "Maximum cores per Dask worker"
  type        = number
  default     = 4
}

variable "dask_worker_memory_max" {
  description = "Maximum memory per Dask worker (GB)"
  type        = number
  default     = 16
}

variable "dask_cluster_max_cores" {
  description = "Maximum total cores per Dask cluster"
  type        = number
  default     = 20
}

# Idle Timeouts
variable "kernel_cull_timeout" {
  description = "Timeout for idle kernels (seconds)"
  type        = number
  default     = 1200  # 20 minutes
}

variable "server_cull_timeout" {
  description = "Timeout for idle servers (seconds)"
  type        = number
  default     = 3600  # 1 hour
}

# S3 Configuration
variable "s3_lifecycle_days" {
  description = "Days before S3 objects are deleted"
  type        = number
  default     = 30
}

variable "force_destroy_s3" {
  description = "Allow destroying S3 bucket with contents"
  type        = bool
  default     = false
}

# Cost Optimization
variable "scale_to_zero" {
  description = "Scale all nodes to zero (emergency cost savings)"
  type        = bool
  default     = false
}

variable "enable_auto_shutdown" {
  description = "Enable automatic shutdown on schedule"
  type        = bool
  default     = false
}

variable "shutdown_schedule" {
  description = "Cron schedule for automatic shutdown"
  type        = string
  default     = "0 19 * * MON-FRI"  # 7 PM weekdays
}

variable "startup_schedule" {
  description = "Cron schedule for automatic startup"
  type        = string
  default     = "0 8 * * MON-FRI"   # 8 AM weekdays
}

# Monitoring
variable "enable_monitoring" {
  description = "Enable CloudWatch monitoring and dashboards"
  type        = bool
  default     = false
}

# Backup Configuration
variable "enable_backups" {
  description = "Enable automated EBS snapshots"
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Days to retain backups"
  type        = number
  default     = 7
}

# Destroy Protection
variable "deletion_protection" {
  description = "Prevent accidental deletion of critical resources"
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot when destroying RDS (if used)"
  type        = bool
  default     = false
}