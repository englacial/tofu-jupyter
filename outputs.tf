# Terra JupyterHub - Output Values

# Cluster Information
output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS cluster"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster's OIDC issuer"
  value       = module.eks.oidc_issuer_url
}

# Network Information
output "vpc_id" {
  description = "ID of the VPC"
  value       = module.networking.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets"
  value       = module.networking.private_subnet_ids
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = module.networking.public_subnet_ids
}

# KMS Information
output "kms_key_id" {
  description = "ID of the KMS key used for encryption"
  value       = module.kms.key_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for encryption"
  value       = module.kms.key_arn
}

# S3 Information
output "s3_bucket_name" {
  description = "Name of the S3 bucket for JupyterHub data"
  value       = module.s3.bucket_name
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket for JupyterHub data"
  value       = module.s3.bucket_arn
}

# Cognito Information
output "cognito_user_pool_id" {
  description = "ID of the Cognito User Pool"
  value       = module.cognito.user_pool_id
}

output "cognito_user_pool_arn" {
  description = "ARN of the Cognito User Pool"
  value       = module.cognito.user_pool_arn
}

output "cognito_client_id" {
  description = "ID of the Cognito App Client"
  value       = module.cognito.client_id
  sensitive   = true
}

output "cognito_domain" {
  description = "Cognito domain for authentication"
  value       = module.cognito.domain
}

# ACM Certificate
output "certificate_arn" {
  description = "ARN of the ACM certificate"
  value       = module.acm.certificate_arn
}

output "certificate_status" {
  description = "Status of the ACM certificate"
  value       = module.acm.certificate_status
}

# JupyterHub Access Information
output "jupyterhub_url" {
  description = "URL to access JupyterHub"
  value       = "https://${var.domain_name}"
}

output "login_instructions" {
  description = "Instructions for logging into JupyterHub"
  value = <<EOT
To access JupyterHub:
1. Navigate to: https://${var.domain_name}
2. Log in with your Cognito credentials
3. First-time users need to be added to Cognito User Pool

To add a new user:
aws cognito-idp admin-create-user \
  --user-pool-id ${module.cognito.user_pool_id} \
  --username <email> \
  --user-attributes Name=email,Value=<email> Name=email_verified,Value=true \
  --temporary-password <temp-password> \
  --message-action SUPPRESS \
  --region ${var.region}
EOT
}

# kubectl Configuration
output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

# Cost Information
output "estimated_monthly_cost" {
  description = "Estimated monthly costs breakdown"
  value = {
    eks_cluster    = "$72.00 (Control plane)"
    main_nodes     = "$${format("%.2f", local.main_node_config.desired_size * 140.16)} (r5.xlarge on-demand)"
    dask_nodes     = "$0.00 when scaled to zero, ~$${format("%.2f", var.dask_node_max_size * 0.096 * 24 * 30)} max with spot"
    nat_gateway    = local.enable_nat_gateway ? "$45.00 per gateway" : "$0.00 (disabled)"
    load_balancer  = "~$20.00"
    s3_storage     = "Variable based on usage"
    cognito        = "Free tier covers most usage"
    total_minimum  = "$${format("%.2f", 72.00 + (local.main_node_config.desired_size * 140.16) + (local.enable_nat_gateway ? 45.00 : 0.00) + 20.00)}"
  }
}

# Debug Information
output "debug_info" {
  description = "Debug information for troubleshooting"
  value = {
    environment           = var.environment
    region               = var.region
    account_id           = data.aws_caller_identity.current.account_id
    nat_gateway_enabled  = local.enable_nat_gateway
    spot_instances       = local.enable_spot_instances
    scale_to_zero        = var.scale_to_zero
    auto_shutdown        = var.enable_auto_shutdown
  }
  sensitive = true
}

# Module-specific Outputs
output "networking_outputs" {
  description = "All outputs from networking module"
  value       = module.networking
  sensitive   = true
}

output "eks_outputs" {
  description = "All outputs from EKS module"
  value       = module.eks
  sensitive   = true
}

output "helm_outputs" {
  description = "All outputs from Helm module"
  value       = module.helm
  sensitive   = true
}

# State Management
output "terraform_state_bucket" {
  description = "S3 bucket used for Terraform state"
  value       = "Check backend.tfvars for state bucket configuration"
}

# Quick Start Commands
output "quick_start" {
  description = "Quick start commands for cluster access"
  value = <<EOT
# Configure kubectl
aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}

# Test connection
kubectl get nodes

# Get JupyterHub pods
kubectl get pods -n jupyterhub

# Get JupyterHub service
kubectl get svc -n jupyterhub

# Follow JupyterHub logs
kubectl logs -n jupyterhub deployment/hub -f

# Get Load Balancer URL
kubectl get svc -n jupyterhub proxy-public -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
EOT
}

# Monitoring URLs (if enabled)
output "monitoring_urls" {
  description = "URLs for monitoring dashboards"
  value = var.enable_monitoring ? {
    cloudwatch_dashboard = "https://console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${local.cluster_name}"
    container_insights   = "https://console.aws.amazon.com/cloudwatch/home?region=${var.region}#container-insights:performance/EKS:cluster?~(query~'${local.cluster_name})"
  } : null
}

# Maintenance Commands
output "maintenance_commands" {
  description = "Useful maintenance commands"
  value = <<EOT
# Scale nodes to zero (cost savings)
kubectl scale deployment hub -n jupyterhub --replicas=0
aws eks update-nodegroup-config --cluster-name ${module.eks.cluster_name} --nodegroup-name main --scaling-config minSize=0,maxSize=0,desiredSize=0

# Restart JupyterHub
kubectl rollout restart deployment/hub -n jupyterhub

# Clean up user pods
kubectl delete pods -n jupyterhub -l component=singleuser-server

# Update JupyterHub configuration
helm upgrade jupyterhub jupyterhub/jupyterhub -n jupyterhub --values helm-values.yaml
EOT
}