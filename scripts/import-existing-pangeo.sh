#!/bin/bash
# Import script for existing "pangeo" EKS cluster into OpenTofu management
# This script safely imports your existing infrastructure without any modifications
# Sensitive data will be encrypted using SOPS for security

set -e

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-pangeo}"
REGION="${REGION:-us-west-1}"
ENVIRONMENT="${ENVIRONMENT:-prod}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Convert YAML to JSON if needed
convert_to_json() {
    local input_file=$1
    local output_file=$2

    # Check if file is already valid JSON
    if jq empty "$input_file" 2>/dev/null; then
        # Already JSON, just copy
        cp "$input_file" "$output_file"
        return 0
    fi

    # File is not JSON, try to convert from YAML
    case "$YAML_PROCESSOR" in
        yq)
            yq eval -o=json '.' "$input_file" > "$output_file"
            ;;
        python)
            python3 -c "
import yaml, json, sys
with open('$input_file', 'r') as f:
    data = yaml.safe_load(f)
with open('$output_file', 'w') as f:
    json.dump(data, f, indent=2)
"
            ;;
        python-script)
            python3 "$(dirname $0)/yaml-to-json.py" "$input_file" "$output_file"
            ;;
        *)
            log_error "Cannot convert YAML to JSON. Please install yq or python3 with PyYAML"
            log_error "Or ensure the yaml-to-json.py script is in the same directory"
            return 1
            ;;
    esac
    return 0
}

# AWS CLI wrapper that handles both JSON and YAML output
aws_to_json() {
    local aws_command=$1
    local output_file=$2
    local temp_file="${output_file}.tmp"

    # Run AWS command
    eval "aws $aws_command" > "$temp_file" 2>/dev/null

    if [ $? -ne 0 ]; then
        rm -f "$temp_file"
        return 1
    fi

    # Convert to JSON if needed
    convert_to_json "$temp_file" "$output_file"
    local result=$?

    # Clean up temp file
    rm -f "$temp_file"

    return $result
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check OpenTofu
    if ! command -v tofu &> /dev/null; then
        log_error "OpenTofu is not installed. Please install it first:"
        echo "curl -sSfL https://get.opentofu.org/install-opentofu.sh | sh"
        exit 1
    fi

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed"
        exit 1
    fi

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_warn "kubectl is not installed - some validations will be skipped"
    fi

    # Check jq for JSON processing
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed. Please install it for JSON processing"
        exit 1
    fi

    # Check SOPS for secret encryption (REQUIRED)
    if ! command -v sops &> /dev/null; then
        log_error "SOPS is not installed. This is REQUIRED for secure handling of sensitive data."
        echo ""
        echo "Please install SOPS first:"
        echo ""
        echo "  macOS:"
        echo "    brew install sops"
        echo ""
        echo "  Linux:"
        echo "    wget https://github.com/getsops/sops/releases/latest/download/sops-linux-amd64"
        echo "    chmod +x sops-linux-amd64"
        echo "    sudo mv sops-linux-amd64 /usr/local/bin/sops"
        echo ""
        echo "  Or download from: https://github.com/getsops/sops/releases"
        echo ""
        log_error "Cannot proceed without SOPS for security reasons."
        exit 1
    fi
    SOPS_AVAILABLE=true
    log_info "✅ SOPS found - sensitive data will be encrypted"

    # Check for YAML processing tools (optional)
    if command -v yq &> /dev/null; then
        YAML_PROCESSOR="yq"
        log_info "Found yq for YAML processing"
    elif command -v python3 &> /dev/null; then
        if python3 -c "import yaml, json" 2>/dev/null; then
            YAML_PROCESSOR="python"
            log_info "Using Python with PyYAML for YAML processing"
        elif [ -f "$(dirname $0)/yaml-to-json.py" ]; then
            YAML_PROCESSOR="python-script"
            log_info "Using bundled Python script for YAML processing"
        else
            log_info "Python found but PyYAML not installed - will force JSON output"
            YAML_PROCESSOR="none"
        fi
    else
        log_info "No YAML processor found - will force JSON output"
        YAML_PROCESSOR="none"
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials not configured"
        exit 1
    fi

    # Detect AWS CLI default output format
    AWS_DEFAULT_OUTPUT=$(aws configure get output 2>/dev/null || echo "json")
    log_info "AWS CLI default output format: ${AWS_DEFAULT_OUTPUT:-json}"

    log_info "Prerequisites check passed"
}

# Check and update .gitignore
check_gitignore() {
    log_info "Checking .gitignore configuration..."

    # Critical entries that must be in .gitignore
    REQUIRED_ENTRIES=(
        "imports/"
        "import-resources.tf"
        "existing-cluster.tf"
        "generated-resources.tf"
        "backend.tfvars"              # Root-level backend config with account ID
        "/terraform.tfvars"           # Root-level tfvars (if created)
        "secrets.yaml"
        "secrets.enc.yaml"
        "import-secrets.yaml"
        "import-secrets.enc.yaml"
        "*.auto.tfvars"              # Any auto-generated tfvars
        "import-*.tfvars"            # Any import-specific tfvars
    )

    # Check if .gitignore exists
    if [ ! -f .gitignore ]; then
        log_warn ".gitignore not found! Creating one..."
        touch .gitignore
    fi

    # Check for missing entries
    MISSING_ENTRIES=()
    for entry in "${REQUIRED_ENTRIES[@]}"; do
        if ! grep -qF "$entry" .gitignore 2>/dev/null; then
            MISSING_ENTRIES+=("$entry")
        fi
    done

    if [ ${#MISSING_ENTRIES[@]} -gt 0 ]; then
        echo ""
        log_warn "⚠️  SECURITY WARNING: The following entries are missing from .gitignore:"
        echo ""
        for entry in "${MISSING_ENTRIES[@]}"; do
            echo "    - $entry"
        done
        echo ""
        log_warn "These files/folders may contain sensitive information like:"
        log_warn "  • AWS Account IDs"
        log_warn "  • IAM Role ARNs"
        log_warn "  • KMS Key IDs"
        log_warn "  • Security Group IDs"
        log_warn "  • OIDC Provider URLs"
        echo ""

        read -p "Do you want to add these entries to .gitignore now? (yes/no): " -r
        if [[ $REPLY =~ ^[Yy]es$ ]]; then
            echo "" >> .gitignore
            echo "# Import-related files (may contain sensitive data)" >> .gitignore
            for entry in "${MISSING_ENTRIES[@]}"; do
                echo "$entry" >> .gitignore
                log_info "Added $entry to .gitignore"
            done
            log_info "✅ .gitignore updated successfully"
        else
            log_error "❌ CRITICAL: Without proper .gitignore entries, sensitive data may be committed to git!"
            log_error "Please add the entries manually before committing any changes."
            read -p "Continue anyway? (yes/no): " -r
            if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
                exit 1
            fi
        fi
    else
        log_info "✅ .gitignore properly configured"
    fi
}

# Gather existing resource information
gather_resources() {
    log_info "Gathering information about cluster: $CLUSTER_NAME"

    # Create imports directory
    mkdir -p imports
    cd imports

    # Get cluster information
    log_info "Fetching EKS cluster details..."
    if ! aws_to_json "eks describe-cluster --name $CLUSTER_NAME --region $REGION" cluster.json; then
        log_error "Cluster $CLUSTER_NAME not found in region $REGION"
        exit 1
    fi

    # Extract key information
    VPC_ID=$(jq -r '.cluster.resourcesVpcConfig.vpcId' cluster.json)
    CLUSTER_ARN=$(jq -r '.cluster.arn' cluster.json)
    CLUSTER_VERSION=$(jq -r '.cluster.version' cluster.json)
    ROLE_ARN=$(jq -r '.cluster.roleArn' cluster.json)
    OIDC_ISSUER=$(jq -r '.cluster.identity.oidc.issuer' cluster.json)

    log_info "Found cluster version: $CLUSTER_VERSION"
    log_info "VPC ID: $VPC_ID"

    # Get node groups
    log_info "Fetching node groups..."
    aws_to_json "eks list-nodegroups --cluster-name $CLUSTER_NAME --region $REGION --query 'nodegroups[]'" nodegroups.json

    # Get detailed node group info
    for nodegroup in $(jq -r '.[]' nodegroups.json); do
        log_info "Fetching details for node group: $nodegroup"
        aws_to_json "eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $nodegroup --region $REGION" "nodegroup-${nodegroup}.json"
    done

    # Get VPC details
    log_info "Fetching VPC configuration..."
    aws_to_json "ec2 describe-vpcs --vpc-ids $VPC_ID --region $REGION" vpc.json

    # Get subnets
    SUBNET_IDS=$(jq -r '.cluster.resourcesVpcConfig.subnetIds[]' cluster.json | tr '\n' ' ')
    aws_to_json "ec2 describe-subnets --subnet-ids $SUBNET_IDS --region $REGION" subnets.json

    # Get security groups
    SG_IDS=$(jq -r '.cluster.resourcesVpcConfig.securityGroupIds[]' cluster.json | tr '\n' ' ')
    if [ ! -z "$SG_IDS" ]; then
        aws_to_json "ec2 describe-security-groups --group-ids $SG_IDS --region $REGION" security-groups.json
    fi

    # Get IAM OIDC provider
    OIDC_ID=$(echo $OIDC_ISSUER | rev | cut -d'/' -f1 | rev)
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}"

    # Check if Helm releases exist
    if command -v helm &> /dev/null; then
        log_info "Fetching Helm releases..."
        helm list -A -o json > helm-releases.json
    fi

    # Save summary
    cat > import-summary.txt << EOF
Cluster Import Summary
======================
Date: $(date)
Cluster Name: $CLUSTER_NAME
Region: $REGION
Version: $CLUSTER_VERSION
VPC ID: $VPC_ID
Cluster ARN: $CLUSTER_ARN
IAM Role: $ROLE_ARN
OIDC Provider: $OIDC_ARN
Node Groups: $(jq -r '.[]' nodegroups.json | tr '\n' ', ')

Next Steps:
1. Review generated import configuration
2. Run: tofu init
3. Run: tofu plan
4. If no changes shown, import is ready
EOF

    log_info "Resource gathering complete. Summary saved to imports/import-summary.txt"
    cd ..
}

# Create encrypted secrets file
create_encrypted_secrets() {
    log_info "Extracting and encrypting sensitive data..."

    # Extract sensitive values from gathered data
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    CLUSTER_ROLE_ARN=$(jq -r '.cluster.roleArn' imports/cluster.json)
    OIDC_ISSUER=$(jq -r '.cluster.identity.oidc.issuer' imports/cluster.json)
    OIDC_ID=$(echo $OIDC_ISSUER | rev | cut -d'/' -f1 | rev)
    OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}"
    KMS_KEY_ARN=$(jq -r '.cluster.encryptionConfig[0].provider.keyArn' imports/cluster.json 2>/dev/null || echo "")

    # Get node role ARNs
    MAIN_NODE_ROLE_ARN=$(jq -r '.nodegroup.nodeRole' imports/nodegroup-main2.json 2>/dev/null || "")
    DASK_NODE_ROLE_ARN=$(jq -r '.nodegroup.nodeRole' imports/nodegroup-dask-workers.json 2>/dev/null || "")

    # Get launch templates
    MAIN_LT_ID=$(jq -r '.nodegroup.launchTemplate.id' imports/nodegroup-main2.json 2>/dev/null || "")
    DASK_LT_ID=$(jq -r '.nodegroup.launchTemplate.id' imports/nodegroup-dask-workers.json 2>/dev/null || "")

    # Create secrets YAML file
    cat > import-secrets.yaml << EOF
# Sensitive data extracted from EKS cluster import
# This file contains sensitive information and should be encrypted with SOPS
# Generated: $(date)

aws:
  account_id: "$ACCOUNT_ID"
  region: "$REGION"

cluster:
  name: "$CLUSTER_NAME"
  role_arn: "$CLUSTER_ROLE_ARN"

oidc:
  issuer: "$OIDC_ISSUER"
  provider_arn: "$OIDC_ARN"

kms:
  key_arn: "$KMS_KEY_ARN"

node_groups:
  main:
    role_arn: "$MAIN_NODE_ROLE_ARN"
    launch_template_id: "$MAIN_LT_ID"
  dask:
    role_arn: "$DASK_NODE_ROLE_ARN"
    launch_template_id: "$DASK_LT_ID"

# State backend configuration
backend:
  bucket: "tofu-state-jupyterhub-${ENVIRONMENT}-${ACCOUNT_ID}"
  dynamodb_table: "tofu-state-lock-${ENVIRONMENT}"
EOF

    # Check for KMS key for SOPS
    KMS_KEY_ALIAS="alias/sops-${CLUSTER_NAME}-${ENVIRONMENT}"
    KMS_KEY_ID=$(aws kms describe-alias --alias-name "$KMS_KEY_ALIAS" 2>/dev/null | jq -r '.AliasArn' || echo "")

    if [ -z "$KMS_KEY_ID" ] || [ "$KMS_KEY_ID" = "null" ]; then
        log_info "KMS key for SOPS not found. Creating one..."
        KMS_KEY_ID=$(aws kms create-key --description "SOPS encryption key for ${CLUSTER_NAME}-${ENVIRONMENT}" \
            --query 'KeyMetadata.KeyId' --output text)
        aws kms create-alias --alias-name "$KMS_KEY_ALIAS" --target-key-id "$KMS_KEY_ID"
        log_info "Created KMS key: $KMS_KEY_ALIAS"
    else
        log_info "Using existing KMS key: $KMS_KEY_ALIAS"
    fi

    # Create SOPS config
    cat > .sops.yaml << EOF
creation_rules:
  - path_regex: .*secrets.*\.yaml$
    kms: arn:aws:kms:${REGION}:${ACCOUNT_ID}:alias/sops-${CLUSTER_NAME}-${ENVIRONMENT}
EOF

    # Encrypt the secrets file
    log_info "Encrypting secrets with SOPS..."
    sops -e import-secrets.yaml > import-secrets.enc.yaml

    # Remove the plain text version
    rm -f import-secrets.yaml

    log_info "✅ Sensitive data encrypted in import-secrets.enc.yaml"
    log_info "To view/edit: sops import-secrets.enc.yaml"
}

# Generate OpenTofu import configuration
generate_import_config() {
    log_info "Generating OpenTofu import configuration..."

    # Read gathered data
    VPC_ID=$(jq -r '.cluster.resourcesVpcConfig.vpcId' imports/cluster.json)
    CLUSTER_VERSION=$(jq -r '.cluster.version' imports/cluster.json)
    CLUSTER_ROLE_ARN=$(jq -r '.cluster.roleArn' imports/cluster.json)
    SUBNET_IDS=$(jq -r '.cluster.resourcesVpcConfig.subnetIds | @json' imports/cluster.json)
    KMS_KEY_ARN=$(jq -r '.cluster.encryptionConfig[0].provider.keyArn' imports/cluster.json 2>/dev/null || echo "")
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

    # Get node role ARNs from each node group
    MAIN_NODE_ROLE_ARN=$(jq -r '.nodegroup.nodeRole' imports/nodegroup-main2.json 2>/dev/null || "")
    DASK_NODE_ROLE_ARN=$(jq -r '.nodegroup.nodeRole' imports/nodegroup-dask-workers.json 2>/dev/null || "")

    # Get actual subnet IDs used by node groups
    MAIN_SUBNETS=$(jq -c '.nodegroup.subnets' imports/nodegroup-main2.json 2>/dev/null || echo '[]')
    DASK_SUBNETS=$(jq -c '.nodegroup.subnets' imports/nodegroup-dask-workers.json 2>/dev/null || echo '[]')

    # Get launch template info
    MAIN_LT_ID=$(jq -r '.nodegroup.launchTemplate.id' imports/nodegroup-main2.json 2>/dev/null || "")
    MAIN_LT_NAME=$(jq -r '.nodegroup.launchTemplate.name' imports/nodegroup-main2.json 2>/dev/null || "")
    DASK_LT_ID=$(jq -r '.nodegroup.launchTemplate.id' imports/nodegroup-dask-workers.json 2>/dev/null || "")
    DASK_LT_NAME=$(jq -r '.nodegroup.launchTemplate.name' imports/nodegroup-dask-workers.json 2>/dev/null || "")

    # Get security groups
    SECURITY_GROUPS=$(jq -c '.cluster.resourcesVpcConfig.securityGroupIds' imports/cluster.json 2>/dev/null || echo '[]')

    # Check for endpoint access settings
    ENDPOINT_PRIVATE=$(jq -r '.cluster.resourcesVpcConfig.endpointPrivateAccess' imports/cluster.json 2>/dev/null || "false")
    ENDPOINT_PUBLIC=$(jq -r '.cluster.resourcesVpcConfig.endpointPublicAccess' imports/cluster.json 2>/dev/null || "true")

    # Get scaling configurations from actual node groups
    MAIN_MIN_SIZE=$(jq -r '.nodegroup.scalingConfig.minSize' imports/nodegroup-main2.json 2>/dev/null || "0")
    MAIN_DESIRED_SIZE=$(jq -r '.nodegroup.scalingConfig.desiredSize' imports/nodegroup-main2.json 2>/dev/null || "0")
    MAIN_MAX_SIZE=$(jq -r '.nodegroup.scalingConfig.maxSize' imports/nodegroup-main2.json 2>/dev/null || "30")

    DASK_MIN_SIZE=$(jq -r '.nodegroup.scalingConfig.minSize' imports/nodegroup-dask-workers.json 2>/dev/null || "0")
    DASK_DESIRED_SIZE=$(jq -r '.nodegroup.scalingConfig.desiredSize' imports/nodegroup-dask-workers.json 2>/dev/null || "0")
    DASK_MAX_SIZE=$(jq -r '.nodegroup.scalingConfig.maxSize' imports/nodegroup-dask-workers.json 2>/dev/null || "30")

    # Create import configuration
    cat > import-resources.tf << 'EOF'
# Auto-generated import configuration for existing EKS cluster
# Generated: $(date)
# Cluster: pangeo

# Import existing EKS cluster
import {
  to = aws_eks_cluster.main
  id = "pangeo"
}

# Import node groups
import {
  to = aws_eks_node_group.main
  id = "pangeo:main2"
}

import {
  to = aws_eks_node_group.dask_workers
  id = "pangeo:dask-workers"
}

EOF

    # Note: VPC is not imported - we use data source instead since it's managed by eksctl

    # Create matching resource definitions with actual values
    cat > existing-cluster.tf << EOF
# Resource definitions for imported cluster
# Using actual values from existing infrastructure

# Data source for existing VPC (managed by eksctl, not by OpenTofu)
# For new clusters, replace this with a proper aws_vpc resource in vpc.tf
data "aws_vpc" "main" {
  id = "$VPC_ID"
}

resource "aws_eks_cluster" "main" {
  name                          = "$CLUSTER_NAME"
  role_arn                      = "$CLUSTER_ROLE_ARN"
  version                       = "$CLUSTER_VERSION"
  bootstrap_self_managed_addons = false  # Important: match existing cluster

  vpc_config {
    subnet_ids              = $SUBNET_IDS
    endpoint_private_access = $ENDPOINT_PRIVATE
    endpoint_public_access  = $ENDPOINT_PUBLIC
EOF

    # Add security groups if they exist
    if [ "$SECURITY_GROUPS" != "[]" ] && [ "$SECURITY_GROUPS" != "null" ]; then
        cat >> existing-cluster.tf << EOF
    security_group_ids      = $SECURITY_GROUPS
EOF
    fi

    cat >> existing-cluster.tf << EOF
  }

EOF

    # Add encryption config if KMS key exists
    if [ ! -z "$KMS_KEY_ARN" ] && [ "$KMS_KEY_ARN" != "null" ]; then
        cat >> existing-cluster.tf << EOF
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = "$KMS_KEY_ARN"
    }
  }

EOF
    fi

    cat >> existing-cluster.tf << EOF
  tags = {
    # Preserve all existing eksctl tags exactly
    "Name"                                        = "eksctl-pangeo-cluster/ControlPlane"
    "alpha.eksctl.io/cluster-name"                = "$CLUSTER_NAME"
    "alpha.eksctl.io/cluster-oidc-enabled"        = "true"
    "alpha.eksctl.io/eksctl-version"              = "0.215.0"
    "eksctl.cluster.k8s.io/v1alpha1/cluster-name" = "$CLUSTER_NAME"
  }

  lifecycle {
    ignore_changes = [
      tags["alpha.eksctl.io/eksctl-version"],
      bootstrap_self_managed_addons
    ]
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "main2"
  node_role_arn   = "$MAIN_NODE_ROLE_ARN"
  subnet_ids      = $MAIN_SUBNETS
  capacity_type   = "ON_DEMAND"

  scaling_config {
    desired_size = $MAIN_DESIRED_SIZE
    max_size     = $MAIN_MAX_SIZE
    min_size     = $MAIN_MIN_SIZE
  }

  instance_types = ["r5n.xlarge"]

EOF

    # Add launch template if it exists
    if [ ! -z "$MAIN_LT_ID" ] && [ "$MAIN_LT_ID" != "null" ]; then
        cat >> existing-cluster.tf << EOF
  launch_template {
    id      = "$MAIN_LT_ID"
    version = "\$Latest"
  }

EOF
    fi

    cat >> existing-cluster.tf << EOF
  # Preserve eksctl labels
  labels = {
    "alpha.eksctl.io/cluster-name"   = "$CLUSTER_NAME"
    "alpha.eksctl.io/nodegroup-name" = "main2"
  }

  tags = {
    # Preserve all existing eksctl tags exactly
    "alpha.eksctl.io/cluster-name"                = "$CLUSTER_NAME"
    "alpha.eksctl.io/eksctl-version"              = "0.215.0"
    "alpha.eksctl.io/nodegroup-name"              = "main2"
    "alpha.eksctl.io/nodegroup-type"              = "managed"
    "eksctl.cluster.k8s.io/v1alpha1/cluster-name" = "$CLUSTER_NAME"
  }

  lifecycle {
    ignore_changes = [
      launch_template[0].version,
      tags["alpha.eksctl.io/eksctl-version"]
    ]
  }
}

resource "aws_eks_node_group" "dask_workers" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "dask-workers"
  node_role_arn   = "$DASK_NODE_ROLE_ARN"
  subnet_ids      = $DASK_SUBNETS
  capacity_type   = "SPOT"

  scaling_config {
    desired_size = $DASK_DESIRED_SIZE
    max_size     = $DASK_MAX_SIZE
    min_size     = $DASK_MIN_SIZE
  }

  instance_types = ["m5.large", "m5.xlarge", "m5.2xlarge", "m5.4xlarge"]

EOF

    # Add launch template if it exists
    if [ ! -z "$DASK_LT_ID" ] && [ "$DASK_LT_ID" != "null" ]; then
        cat >> existing-cluster.tf << EOF
  launch_template {
    id      = "$DASK_LT_ID"
    version = "\$Latest"
  }

EOF
    fi

    cat >> existing-cluster.tf << EOF
  # Important: Spot instances taint
  taint {
    key    = "lifecycle"
    value  = "spot"
    effect = "NO_EXECUTE"
  }

  # Preserve eksctl labels
  labels = {
    "alpha.eksctl.io/cluster-name"   = "$CLUSTER_NAME"
    "alpha.eksctl.io/nodegroup-name" = "dask-workers"
  }

  tags = {
    # Preserve all existing eksctl tags exactly
    "alpha.eksctl.io/cluster-name"                = "$CLUSTER_NAME"
    "alpha.eksctl.io/eksctl-version"              = "0.215.0"
    "alpha.eksctl.io/nodegroup-name"              = "dask-workers"
    "alpha.eksctl.io/nodegroup-type"              = "managed"
    "eksctl.cluster.k8s.io/v1alpha1/cluster-name" = "$CLUSTER_NAME"
  }

  lifecycle {
    ignore_changes = [
      launch_template[0].version,
      tags["alpha.eksctl.io/eksctl-version"]
    ]
  }
}

# Provider configuration
provider "aws" {
  region = "$REGION"
}

# Terraform configuration
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "registry.opentofu.org/hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
EOF

    log_info "Import configuration generated"
}

# Create backend configuration
setup_backend() {
    log_info "Setting up OpenTofu backend..."

    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    STATE_BUCKET="tofu-state-jupyterhub-${ENVIRONMENT}-${ACCOUNT_ID}"

    # Check if state bucket exists
    if aws s3api head-bucket --bucket "$STATE_BUCKET" 2>/dev/null; then
        log_info "State bucket already exists: $STATE_BUCKET"
    else
        log_info "Creating state bucket: $STATE_BUCKET"

        if [ "$REGION" == "us-east-1" ]; then
            aws s3api create-bucket --bucket $STATE_BUCKET --region $REGION
        else
            aws s3api create-bucket --bucket $STATE_BUCKET --region $REGION \
                --create-bucket-configuration LocationConstraint=$REGION
        fi

        # Enable versioning
        aws s3api put-bucket-versioning --bucket $STATE_BUCKET \
            --versioning-configuration Status=Enabled
    fi

    # Create backend configuration
    cat > backend.tfvars << EOF
bucket         = "$STATE_BUCKET"
key            = "terraform.tfstate"
region         = "$REGION"
encrypt        = true
dynamodb_table = "tofu-state-lock-${ENVIRONMENT}"
EOF

    log_info "Backend configuration created"
}

# Execute import
execute_import() {
    log_info "Executing OpenTofu import..."

    # Initialize OpenTofu
    log_info "Initializing OpenTofu..."
    tofu init -backend-config=backend.tfvars

    # Generate full configuration from existing resources
    log_info "Generating configuration from existing resources..."
    tofu plan -generate-config-out=generated-resources.tf

    # Show what will be imported
    log_info "Validating import (no changes should be required)..."
    tofu plan

    # Check if there are changes
    if tofu plan -detailed-exitcode > /dev/null 2>&1; then
        log_info "✅ No changes detected - import configuration matches existing infrastructure"

        read -p "Do you want to proceed with import? (yes/no): " -r
        if [[ $REPLY =~ ^[Yy]es$ ]]; then
            log_info "Starting import..."

            # Import cluster
            tofu import aws_eks_cluster.main $CLUSTER_NAME

            # Import node groups
            tofu import aws_eks_node_group.main "${CLUSTER_NAME}:main2"
            tofu import aws_eks_node_group.dask_workers "${CLUSTER_NAME}:dask-workers"

            log_info "✅ Import completed successfully!"

            # Final validation
            log_info "Running final validation..."
            tofu plan
        else
            log_warn "Import cancelled by user"
        fi
    else
        log_warn "Configuration shows changes. Please review and adjust to match existing resources."
        log_warn "Run 'tofu plan' to see what changes are detected."
    fi
}

# Main execution
main() {
    echo "============================================="
    echo "OpenTofu Import Script for EKS Cluster"
    echo "============================================="
    echo "Cluster: $CLUSTER_NAME"
    echo "Region: $REGION"
    echo "Environment: $ENVIRONMENT"
    echo "============================================="
    echo ""

    check_prerequisites
    check_gitignore  # Check .gitignore BEFORE gathering resources
    gather_resources
    create_encrypted_secrets  # Create encrypted secrets file
    generate_import_config
    setup_backend

    echo ""
    log_info "Preparation complete!"
    echo ""
    echo "Generated files:"
    echo "  - import-resources.tf     (import blocks)"
    echo "  - existing-cluster.tf      (resource definitions)"
    echo "  - backend.tfvars          (state backend config)"
    echo "  - import-secrets.enc.yaml (ENCRYPTED sensitive data)"
    echo "  - .sops.yaml              (SOPS configuration)"
    echo "  - imports/                (gathered resource data)"
    echo ""
    echo "🔒 SECURITY NOTES:"
    echo "  - Sensitive data has been encrypted in import-secrets.enc.yaml"
    echo "  - The imports/ folder contains raw AWS data (excluded from git)"
    echo "  - Use 'sops import-secrets.enc.yaml' to view/edit secrets"
    echo "  - All sensitive files are excluded from git via .gitignore"
    echo ""
    echo "Next steps:"
    echo "1. Review the generated configuration files"
    echo "2. Adjust resource definitions if needed"
    echo "3. Run: tofu init -backend-config=backend.tfvars"
    echo "4. Run: tofu plan (should show no changes)"
    echo "5. Run: tofu import aws_eks_cluster.main pangeo"
    echo ""

    read -p "Do you want to continue with automatic import? (yes/no): " -r
    if [[ $REPLY =~ ^[Yy]es$ ]]; then
        execute_import
    else
        log_info "You can run the import manually using the generated files"
    fi
}

# Run main function
main