#!/bin/bash
# Bootstrap script for Terraform backend infrastructure
# This creates the S3 bucket and DynamoDB table needed for remote state

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
ENV=${1:-dev}
REGION=${2:-us-west-2}
BUCKET_NAME="terraform-state-jupyterhub-${ENV}"
DYNAMODB_TABLE="terraform-state-lock-${ENV}"

echo -e "${GREEN}Bootstrapping Terraform backend for environment: ${ENV}${NC}"
echo "Region: ${REGION}"
echo "Bucket: ${BUCKET_NAME}"
echo "DynamoDB Table: ${DYNAMODB_TABLE}"
echo ""

# Check if AWS CLI is configured
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo -e "${RED}Error: AWS CLI is not configured${NC}"
    echo "Run: aws configure"
    exit 1
fi

# Create S3 bucket
echo -e "${YELLOW}Creating S3 bucket...${NC}"
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
    echo "Bucket ${BUCKET_NAME} already exists"
else
    aws s3api create-bucket \
        --bucket "${BUCKET_NAME}" \
        --region "${REGION}" \
        $(if [ "${REGION}" != "us-east-1" ]; then echo "--create-bucket-configuration LocationConstraint=${REGION}"; fi)

    # Enable versioning
    aws s3api put-bucket-versioning \
        --bucket "${BUCKET_NAME}" \
        --versioning-configuration Status=Enabled

    # Enable encryption
    aws s3api put-bucket-encryption \
        --bucket "${BUCKET_NAME}" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }'

    # Block public access
    aws s3api put-public-access-block \
        --bucket "${BUCKET_NAME}" \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    echo -e "${GREEN}S3 bucket created successfully${NC}"
fi

# Create DynamoDB table for state locking
echo -e "${YELLOW}Creating DynamoDB table...${NC}"
if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE}" --region "${REGION}" >/dev/null 2>&1; then
    echo "Table ${DYNAMODB_TABLE} already exists"
else
    aws dynamodb create-table \
        --table-name "${DYNAMODB_TABLE}" \
        --attribute-definitions AttributeName=LockID,AttributeType=S \
        --key-schema AttributeName=LockID,KeyType=HASH \
        --billing-mode PAY_PER_REQUEST \
        --region "${REGION}" \
        --tags Key=Environment,Value="${ENV}" Key=Terraform,Value=true Key=Purpose,Value=state-lock

    # Wait for table to be active
    echo "Waiting for table to be active..."
    aws dynamodb wait table-exists --table-name "${DYNAMODB_TABLE}" --region "${REGION}"

    echo -e "${GREEN}DynamoDB table created successfully${NC}"
fi

# Create backend configuration file
BACKEND_CONFIG="../environments/${ENV}/backend.tfvars"
echo -e "${YELLOW}Creating backend configuration...${NC}"
cat > "${BACKEND_CONFIG}" << EOF
# Terraform Backend Configuration - ${ENV}
# This configures where Terraform state is stored
# Generated on $(date)

bucket         = "${BUCKET_NAME}"
key            = "jupyterhub/terraform.tfstate"
region         = "${REGION}"
encrypt        = true
dynamodb_table = "${DYNAMODB_TABLE}"
EOF

echo -e "${GREEN}Backend configuration written to ${BACKEND_CONFIG}${NC}"

# Create KMS key for SOPS (optional)
echo -e "${YELLOW}Creating KMS key for SOPS...${NC}"
KMS_ALIAS="alias/sops-jupyterhub-${ENV}"
if aws kms describe-alias --alias-name "${KMS_ALIAS}" --region "${REGION}" >/dev/null 2>&1; then
    echo "KMS alias ${KMS_ALIAS} already exists"
    KMS_KEY_ID=$(aws kms describe-alias --alias-name "${KMS_ALIAS}" --region "${REGION}" --query 'AliasArn' --output text)
else
    KMS_KEY_ID=$(aws kms create-key \
        --description "SOPS key for Terra JupyterHub ${ENV}" \
        --tags TagKey=Environment,TagValue="${ENV}" TagKey=Application,TagValue=jupyterhub-terraform \
        --region "${REGION}" \
        --query 'KeyMetadata.KeyId' \
        --output text)

    aws kms create-alias \
        --alias-name "${KMS_ALIAS}" \
        --target-key-id "${KMS_KEY_ID}" \
        --region "${REGION}"

    echo -e "${GREEN}KMS key created: ${KMS_KEY_ID}${NC}"
fi

# Get KMS key ARN
KMS_ARN=$(aws kms describe-key --key-id "${KMS_KEY_ID}" --region "${REGION}" --query 'KeyMetadata.Arn' --output text)

# Create SOPS configuration
SOPS_CONFIG="../environments/${ENV}/.sops.yaml"
echo -e "${YELLOW}Creating SOPS configuration...${NC}"
cat > "${SOPS_CONFIG}" << EOF
# SOPS Configuration for ${ENV}
creation_rules:
  - kms: ${KMS_ARN}
EOF

echo -e "${GREEN}SOPS configuration written to ${SOPS_CONFIG}${NC}"

# Summary
echo ""
echo -e "${GREEN}=== Bootstrap Complete ===${NC}"
echo ""
echo "Backend resources created:"
echo "  S3 Bucket: ${BUCKET_NAME}"
echo "  DynamoDB Table: ${DYNAMODB_TABLE}"
echo "  KMS Key: ${KMS_ARN}"
echo ""
echo "Next steps:"
echo "1. Copy secrets.yaml.example to secrets.yaml:"
echo "   cp environments/${ENV}/secrets.yaml.example environments/${ENV}/secrets.yaml"
echo ""
echo "2. Edit and encrypt secrets:"
echo "   sops -e -i environments/${ENV}/secrets.yaml"
echo ""
echo "3. Initialize Terraform:"
echo "   make init ENV=${ENV}"
echo ""
echo "4. Deploy infrastructure:"
echo "   make deploy ENV=${ENV}"