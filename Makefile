# Terra JupyterHub - OpenTofu Makefile
# Automated deployment and management for JupyterHub on EKS using OpenTofu

SHELL := /bin/bash
.PHONY: help init plan apply destroy clean validate fmt lint cost-estimate backup restore scale-down scale-up status

# Variables
ENVIRONMENT ?= dev
REGION ?= us-west-2
CLUSTER_NAME ?= jupyterhub
AUTO_APPROVE ?= false

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
NC := \033[0m # No Color

# OpenTofu/Terraform backend config
BACKEND_CONFIG := environments/$(ENVIRONMENT)/backend.tfvars
TFVARS := environments/$(ENVIRONMENT)/terraform.tfvars
STATE_BUCKET := terraform-state-$(CLUSTER_NAME)-$(ENVIRONMENT)

# Check for OpenTofu, fall back to Terraform if not found
TERRAFORM_CMD := $(shell which tofu 2>/dev/null || which terraform 2>/dev/null)
ifeq ($(TERRAFORM_CMD),)
$(error Neither OpenTofu nor Terraform found in PATH. Please install OpenTofu: https://opentofu.org/docs/intro/install/)
endif

# Extract binary name for messages
TF_BINARY := $(shell basename $(TERRAFORM_CMD))

##@ General

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Environment Variables:"
	@echo "  ENVIRONMENT    - Target environment (current: $(ENVIRONMENT))"
	@echo "  REGION        - AWS region (current: $(REGION))"
	@echo "  AUTO_APPROVE  - Skip approval prompts (current: $(AUTO_APPROVE))"
	@echo ""
	@echo "Examples:"
	@echo "  make init ENVIRONMENT=prod"
	@echo "  make plan"
	@echo "  make apply AUTO_APPROVE=true"
	@echo ""
	@echo "Using: $(TF_BINARY) at $(TERRAFORM_CMD)"

##@ OpenTofu/Terraform Operations

init: check-env ## Initialize OpenTofu with backend config
	@echo -e "$(GREEN)Initializing $(TF_BINARY) for environment: $(ENVIRONMENT)$(NC)"
	@if [ ! -f $(BACKEND_CONFIG) ]; then \
		echo -e "$(RED)Backend config not found at $(BACKEND_CONFIG)$(NC)"; \
		echo "Creating from template..."; \
		./scripts/bootstrap-backend.sh $(ENVIRONMENT); \
	fi
	@if [ ! -f $(TFVARS) ]; then \
		echo -e "$(RED)Terraform vars not found at $(TFVARS)$(NC)"; \
		echo "Please create $(TFVARS) from the example file"; \
		exit 1; \
	fi
	$(TERRAFORM_CMD) init -backend-config=$(BACKEND_CONFIG) -reconfigure

validate: init ## Validate OpenTofu configuration
	@echo -e "$(GREEN)Validating $(TF_BINARY) configuration...$(NC)"
	$(TERRAFORM_CMD) validate

fmt: ## Format OpenTofu files
	@echo -e "$(GREEN)Formatting $(TF_BINARY) files...$(NC)"
	$(TERRAFORM_CMD) fmt -recursive

fmt-check: ## Check if OpenTofu files are formatted
	@echo -e "$(GREEN)Checking $(TF_BINARY) formatting...$(NC)"
	$(TERRAFORM_CMD) fmt -check -recursive

plan: init ## Create execution plan
	@echo -e "$(GREEN)Creating $(TF_BINARY) plan for environment: $(ENVIRONMENT)$(NC)"
	$(TERRAFORM_CMD) plan -var-file=$(TFVARS) -out=tfplan

apply: plan ## Apply changes
	@echo -e "$(YELLOW)Applying changes to environment: $(ENVIRONMENT)$(NC)"
	@if [ "$(AUTO_APPROVE)" = "true" ]; then \
		$(TERRAFORM_CMD) apply tfplan; \
	else \
		$(TERRAFORM_CMD) apply tfplan; \
	fi
	@echo -e "$(GREEN)Deployment complete!$(NC)"
	@echo "Run 'make status' to check cluster status"

destroy: init ## Destroy all resources (WARNING: Destructive!)
	@echo -e "$(RED)WARNING: This will destroy all resources in environment: $(ENVIRONMENT)$(NC)"
	@echo "Press Ctrl+C to cancel, or Enter to continue..."
	@read dummy
	@if [ "$(AUTO_APPROVE)" = "true" ]; then \
		$(TERRAFORM_CMD) destroy -var-file=$(TFVARS) -auto-approve; \
	else \
		$(TERRAFORM_CMD) destroy -var-file=$(TFVARS); \
	fi

refresh: init ## Refresh state
	@echo -e "$(GREEN)Refreshing $(TF_BINARY) state...$(NC)"
	$(TERRAFORM_CMD) refresh -var-file=$(TFVARS)

output: ## Show outputs
	@$(TERRAFORM_CMD) output -json | jq '.'

show: ## Show current state
	@$(TERRAFORM_CMD) show

##@ Kubernetes Operations

kubeconfig: ## Configure kubectl
	@echo -e "$(GREEN)Configuring kubectl...$(NC)"
	@CLUSTER=$$($(TERRAFORM_CMD) output -raw cluster_name 2>/dev/null) && \
	aws eks update-kubeconfig --region $(REGION) --name $$CLUSTER
	@echo "kubectl configured. Try: kubectl get nodes"

get-nodes: kubeconfig ## Get cluster nodes
	kubectl get nodes

get-pods: kubeconfig ## Get JupyterHub pods
	kubectl get pods -n jupyterhub

logs-hub: kubeconfig ## Show hub logs
	kubectl logs -n jupyterhub deployment/hub -f

logs-proxy: kubeconfig ## Show proxy logs
	kubectl logs -n jupyterhub deployment/proxy -f

shell-hub: kubeconfig ## Open shell in hub pod
	kubectl exec -it -n jupyterhub deployment/hub -- /bin/bash

##@ Cost Management

cost-estimate: init ## Estimate costs (requires Infracost)
	@command -v infracost >/dev/null 2>&1 || { echo "Infracost not installed. See: https://www.infracost.io/docs/"; exit 1; }
	@echo -e "$(GREEN)Estimating costs for environment: $(ENVIRONMENT)$(NC)"
	infracost breakdown --path . --terraform-var-file $(TFVARS)

scale-down: kubeconfig ## Scale cluster to zero (save costs)
	@echo -e "$(YELLOW)Scaling down cluster to save costs...$(NC)"
	kubectl scale deployment --all -n jupyterhub --replicas=0
	@CLUSTER=$$($(TERRAFORM_CMD) output -raw cluster_name) && \
	aws eks update-nodegroup-config \
		--cluster-name $$CLUSTER \
		--nodegroup-name main \
		--scaling-config minSize=0,desiredSize=0,maxSize=5 \
		--region $(REGION)
	@echo -e "$(GREEN)Cluster scaled down. Run 'make scale-up' to restore.$(NC)"

scale-up: kubeconfig ## Scale cluster back up
	@echo -e "$(GREEN)Scaling up cluster...$(NC)"
	@CLUSTER=$$($(TERRAFORM_CMD) output -raw cluster_name) && \
	aws eks update-nodegroup-config \
		--cluster-name $$CLUSTER \
		--nodegroup-name main \
		--scaling-config minSize=1,desiredSize=1,maxSize=5 \
		--region $(REGION)
	kubectl scale deployment hub -n jupyterhub --replicas=1
	kubectl scale deployment proxy -n jupyterhub --replicas=1
	@echo -e "$(GREEN)Cluster scaled up. Services will be available in a few minutes.$(NC)"

##@ Maintenance

backup: ## Backup OpenTofu state
	@echo -e "$(GREEN)Backing up $(TF_BINARY) state...$(NC)"
	@TIMESTAMP=$$(date +%Y%m%d-%H%M%S) && \
	$(TERRAFORM_CMD) state pull > backups/terraform-state-$$TIMESTAMP.json
	@echo "State backed up to backups/"

clean: ## Clean up temporary files
	@echo -e "$(YELLOW)Cleaning up temporary files...$(NC)"
	rm -rf .terraform .terraform.lock.hcl tfplan *.tfstate *.tfstate.*
	@echo -e "$(GREEN)Cleanup complete$(NC)"

status: kubeconfig ## Check cluster and application status
	@echo -e "$(GREEN)=== Cluster Status ===$(NC)"
	@CLUSTER=$$($(TERRAFORM_CMD) output -raw cluster_name 2>/dev/null) && \
	aws eks describe-cluster --name $$CLUSTER --region $(REGION) --query 'cluster.status' --output text
	@echo ""
	@echo -e "$(GREEN)=== Node Status ===$(NC)"
	kubectl get nodes 2>/dev/null || echo "kubectl not configured"
	@echo ""
	@echo -e "$(GREEN)=== JupyterHub Status ===$(NC)"
	kubectl get pods -n jupyterhub 2>/dev/null || echo "JupyterHub namespace not found"
	@echo ""
	@echo -e "$(GREEN)=== Service URLs ===$(NC)"
	@echo "JupyterHub URL: $$($(TERRAFORM_CMD) output -raw jupyterhub_url 2>/dev/null)"

test-login: ## Test JupyterHub login
	@URL=$$($(TERRAFORM_CMD) output -raw jupyterhub_url 2>/dev/null) && \
	echo -e "$(GREEN)Testing JupyterHub at $$URL$(NC)" && \
	curl -s -o /dev/null -w "%{http_code}" $$URL || echo "Connection failed"

##@ Development

lint: fmt-check validate ## Run all linters
	@echo -e "$(GREEN)Running linters...$(NC)"
	@command -v tflint >/dev/null 2>&1 || { echo "tflint not installed. See: https://github.com/terraform-linters/tflint"; exit 1; }
	tflint --init
	tflint

docs: ## Generate documentation
	@echo -e "$(GREEN)Generating documentation...$(NC)"
	@command -v terraform-docs >/dev/null 2>&1 || { echo "terraform-docs not installed. See: https://terraform-docs.io/"; exit 1; }
	terraform-docs markdown . > TERRAFORM_DOCS.md

graph: ## Generate resource graph
	@echo -e "$(GREEN)Generating resource graph...$(NC)"
	$(TERRAFORM_CMD) graph | dot -Tpng > infrastructure-graph.png
	@echo "Graph saved to infrastructure-graph.png"

##@ Import Operations

import-existing: ## Import existing Pangeo cluster
	@echo -e "$(GREEN)Starting import of existing cluster...$(NC)"
	./scripts/import-existing-pangeo.sh

post-import-validate: ## Validate imported configuration
	@echo -e "$(GREEN)Validating imported configuration...$(NC)"
	$(TERRAFORM_CMD) init -backend-config=backend.tfvars
	$(TERRAFORM_CMD) plan
	@echo -e "$(GREEN)If plan shows no changes, import was successful!$(NC)"

##@ Utilities

check-env: ## Check environment setup
	@echo -e "$(GREEN)Checking environment setup...$(NC)"
	@echo "OpenTofu/Terraform: $(TF_BINARY) at $(TERRAFORM_CMD)"
	@echo "AWS CLI: $$(which aws)"
	@echo "kubectl: $$(which kubectl || echo 'not found')"
	@echo "Environment: $(ENVIRONMENT)"
	@echo "Region: $(REGION)"
	@aws sts get-caller-identity >/dev/null 2>&1 || { echo -e "$(RED)AWS credentials not configured$(NC)"; exit 1; }
	@echo -e "$(GREEN)Environment check passed$(NC)"

install-tools: ## Install required tools
	@echo -e "$(GREEN)Installing required tools...$(NC)"
	@echo "Installing OpenTofu..."
	@curl -fsSL https://get.opentofu.org/install-opentofu.sh | bash -s -- --install-method standalone
	@echo "Installing kubectl..."
	@curl -LO "https://dl.k8s.io/release/$$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
	@chmod +x kubectl && sudo mv kubectl /usr/local/bin/
	@echo "Installing Helm..."
	@curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
	@echo -e "$(GREEN)Tools installed$(NC)"

# Hidden targets for advanced users
.PHONY: force-unlock console debug

force-unlock: ## Force unlock state (use with caution)
	@echo -e "$(RED)Force unlocking state...$(NC)"
	$(TERRAFORM_CMD) force-unlock $(LOCK_ID)

console: init ## Open OpenTofu console
	$(TERRAFORM_CMD) console

debug: ## Enable debug output
	TF_LOG=DEBUG $(TERRAFORM_CMD) plan -var-file=$(TFVARS)