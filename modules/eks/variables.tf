# EKS Module - Variables

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the cluster"
  type        = string
  default     = "1.29"
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where cluster will be deployed"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for the cluster"
  type        = list(string)
}

variable "kms_key_id" {
  description = "KMS key ID for encryption"
  type        = string
}

# Main Node Group
variable "main_node_instance_types" {
  description = "Instance types for main node group"
  type        = list(string)
}

variable "main_node_min_size" {
  description = "Minimum size of main node group"
  type        = number
}

variable "main_node_desired_size" {
  description = "Desired size of main node group"
  type        = number
}

variable "main_node_max_size" {
  description = "Maximum size of main node group"
  type        = number
}

# Dask Worker Node Group
variable "dask_node_instance_types" {
  description = "Instance types for Dask worker nodes"
  type        = list(string)
}

variable "dask_node_min_size" {
  description = "Minimum size of Dask node group"
  type        = number
}

variable "dask_node_desired_size" {
  description = "Desired size of Dask node group"
  type        = number
}

variable "dask_node_max_size" {
  description = "Maximum size of Dask node group"
  type        = number
}

variable "enable_spot_instances" {
  description = "Use spot instances for Dask workers"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}