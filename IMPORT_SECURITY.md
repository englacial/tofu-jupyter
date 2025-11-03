# Import Security Guide

## Overview

When importing existing EKS infrastructure into OpenTofu, the import process must gather sensitive information about your AWS resources. This guide explains how we handle this sensitive data securely.

## Sensitive Data Collected

The import script collects the following potentially sensitive information:

### High Sensitivity
- **AWS Account ID**: Embedded in all ARNs
- **IAM Role ARNs**: For cluster and node groups
- **KMS Key ARNs**: Encryption keys
- **OIDC Provider URLs**: Authentication endpoints

### Medium Sensitivity
- **Security Group IDs**: Network access controls
- **Subnet IDs**: Network topology
- **Launch Template IDs**: Instance configurations

### Low Sensitivity (Public Information)
- **VPC IDs**: Network identifiers
- **Cluster Name**: Already known
- **Instance Types**: EC2 specifications
- **Kubernetes Version**: Cluster version

## Security Measures

### 1. SOPS Encryption (Required)

SOPS is REQUIRED for the import script to run. The script will:
1. Create a KMS key for SOPS encryption (if not exists)
2. Encrypt all sensitive data in `import-secrets.enc.yaml`
3. Delete the plain text version automatically
4. Configure `.sops.yaml` for automatic encryption

**SOPS Installation (Required):**
```bash
# macOS
brew install sops

# Linux
wget https://github.com/getsops/sops/releases/latest/download/sops-linux-amd64
chmod +x sops-linux-amd64
sudo mv sops-linux-amd64 /usr/local/bin/sops

# Verify installation
sops --version
```

⚠️ **Note**: The import script will fail if SOPS is not installed. This is intentional to prevent storing sensitive data in plain text.

### 2. .gitignore Protection

The import script automatically checks and updates `.gitignore` to exclude:
- `imports/` - Raw JSON data from AWS
- `import-resources.tf` - Contains ARNs
- `existing-cluster.tf` - Contains sensitive IDs
- `backend.tfvars` - Contains account ID
- `import-secrets.yaml` - Unencrypted secrets
- `import-secrets.enc.yaml` - Encrypted secrets (still excluded)
- `.sops.yaml` - SOPS configuration

### 3. File Organization

```
tofu_jupyter/
├── .gitignore                    # Updated with security entries
├── imports/                      # ⚠️ NEVER COMMIT - Raw AWS data
│   ├── cluster.json              # Contains role ARNs, OIDC info
│   ├── nodegroup-*.json          # Contains IAM roles
│   └── *.json                    # Other AWS resource data
├── import-secrets.enc.yaml       # ✅ Encrypted sensitive data
├── .sops.yaml                    # SOPS configuration for encryption
├── import-resources.tf           # ⚠️ Contains ARNs - excluded from git
├── existing-cluster.tf           # ⚠️ Contains sensitive IDs - excluded from git
└── backend.tfvars               # ⚠️ Contains account ID - excluded from git
```

## Working with Encrypted Secrets

### View Encrypted Secrets
```bash
sops import-secrets.enc.yaml
```

### Edit Encrypted Secrets
```bash
sops import-secrets.enc.yaml
# Opens in your default editor, saves encrypted on exit
```

### Decrypt to stdout (for scripts)
```bash
sops -d import-secrets.enc.yaml
```

### Extract specific value
```bash
sops -d import-secrets.enc.yaml | yq '.aws.account_id'
```

## Security Checklist

Before running the import:
- [ ] Install SOPS (REQUIRED - script will fail without it)
- [ ] Verify `.gitignore` is properly configured
- [ ] Have AWS KMS permissions for creating encryption keys

After running the import:
- [ ] Verify `imports/` folder is in `.gitignore`
- [ ] Verify no `.tfvars` files are tracked in git
- [ ] Verify `import-secrets.enc.yaml` exists (encrypted)
- [ ] Verify NO plain text `import-secrets.yaml` exists
- [ ] Run `git status` to ensure no sensitive files are staged

Before committing:
- [ ] Run `git diff --staged` to review changes
- [ ] Search for account IDs: `git diff --staged | grep -E '\d{12}'`
- [ ] Search for ARNs: `git diff --staged | grep 'arn:aws'`
- [ ] Ensure only template/example files are committed

## What Can Be Safely Committed

These files are safe to commit as they use variables/placeholders:
- `main.tf` - Uses variables for all values
- `variables.tf` - Defines variables with defaults
- `outputs.tf` - References modules and variables
- `modules/**/*.tf` - Module definitions
- `environments/*/terraform.tfvars` - With example.com domains only

## Emergency: If Sensitive Data Was Committed

If sensitive data was accidentally committed:

1. **DO NOT PUSH** to remote repository
2. Remove from history immediately:
   ```bash
   git filter-branch --force --index-filter \
     'git rm --cached --ignore-unmatch <sensitive-file>' \
     --prune-empty --tag-name-filter cat -- --all
   ```
3. Clean up:
   ```bash
   rm -rf .git/refs/original/
   git reflog expire --expire=now --all
   git gc --prune=now --aggressive
   ```
4. If already pushed, consider the data compromised and:
   - Rotate all AWS credentials
   - Create new IAM roles
   - Update security groups
   - Notify your security team

## Best Practices

1. **Always run the import script before checking git status**
2. **Never commit the imports/ folder**
3. **Use SOPS for all sensitive data**
4. **Review all generated files before committing**
5. **Keep sensitive values in encrypted files or environment variables**
6. **Use data sources in Terraform to look up sensitive values at runtime**

## Questions or Concerns?

If you're unsure whether something is sensitive, err on the side of caution:
- Don't commit it
- Encrypt it with SOPS
- Ask your security team for guidance