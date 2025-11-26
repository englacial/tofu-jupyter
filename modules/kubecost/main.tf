# Kubecost Module - Cost Monitoring for Kubernetes
# Provides per-pod, per-user, per-namespace cost tracking with AWS integration

terraform {
  required_providers {
    helm = {
      source  = "registry.opentofu.org/hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "registry.opentofu.org/hashicorp/kubernetes"
      version = "~> 2.24"
    }
    aws = {
      source  = "registry.opentofu.org/hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Create namespace for Kubecost
resource "kubernetes_namespace" "kubecost" {
  metadata {
    name = "kubecost"
    labels = {
      name = "kubecost"
    }
  }
}

# Service account for Kubecost (IRSA integration)
resource "kubernetes_service_account" "kubecost" {
  metadata {
    name      = "kubecost-cost-analyzer"
    namespace = kubernetes_namespace.kubecost.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = var.kubecost_irsa_role_arn
    }
  }
}

# Kubecost Helm Release
resource "helm_release" "kubecost" {
  name       = "kubecost"
  repository = "oci://public.ecr.aws/kubecost"
  chart      = "cost-analyzer"
  version    = "2.4.1"  # Latest stable version
  namespace  = kubernetes_namespace.kubecost.metadata[0].name

  # Wait for CRDs and pods to be ready
  wait             = true
  timeout          = 600
  create_namespace = false

  values = [
    yamlencode({
      # Global configuration
      global = {
        # Use Prometheus included with Kubecost (not external)
        prometheus = {
          enabled = true
          fqdn    = "http://kubecost-prometheus-server.${kubernetes_namespace.kubecost.metadata[0].name}.svc"
        }
      }

      # Kubecost product configuration
      kubecostProductConfigs = {
        # Cluster identification
        clusterName           = var.cluster_name
        productKey            = ""  # Free tier (15-day retention)

        # AWS Cost & Usage Report integration
        awsServiceKeyName     = "aws-access-key-id"
        awsServiceKeyPassword = "aws-secret-access-key"
        awsSpotDataRegion     = var.region
        awsSpotDataBucket     = var.cur_bucket_name
        awsSpotDataPrefix     = var.cur_prefix
        athenaProjectID       = data.aws_caller_identity.current.account_id
        athenaBucketName      = var.cur_bucket_name
        athenaRegion          = var.region
        athenaDatabase        = "athenacurcfn_kubecost_cur"
        athenaTable           = "kubecost_cur"
        athenaWorkgroup       = "primary"

        # Metrics configuration
        metricsConfigs = {
          disabledMetrics = []
        }
      }

      # Kubecost cost-analyzer deployment
      kubecostDeployment = {
        # Use service account with IRSA
        serviceAccount = {
          create = false  # We created it above
          name   = kubernetes_service_account.kubecost.metadata[0].name
        }

        # Resource requests/limits
        resources = {
          requests = {
            cpu    = "200m"
            memory = "1.5Gi"
          }
          limits = {
            cpu    = "1000m"
            memory = "2Gi"
          }
        }

        # Node affinity - run on system nodes only
        nodeSelector = var.node_selector

        tolerations = var.tolerations
      }

      # Prometheus configuration (bundled with Kubecost)
      prometheus = {
        server = {
          # Persistent volume for metrics storage
          persistentVolume = {
            enabled      = true
            size         = "32Gi"
            storageClass = "gp3"
          }

          # Resource requests/limits
          resources = {
            requests = {
              cpu    = "500m"
              memory = "2Gi"
            }
            limits = {
              cpu    = "2000m"
              memory = "4Gi"
            }
          }

          # Retention period (15 days for free tier)
          retention = "15d"

          # Node affinity - run on system nodes
          nodeSelector = var.node_selector

          tolerations = var.tolerations

          # Global scrape configuration
          global = {
            scrape_interval = "60s"
            evaluation_interval = "60s"
          }
        }

        # Disable alertmanager (not needed for cost monitoring)
        alertmanager = {
          enabled = false
        }

        # Disable pushgateway
        pushgateway = {
          enabled = false
        }

        # Node exporter for per-node metrics
        nodeExporter = {
          enabled = true

          # Run on ALL nodes (daemonset)
          nodeSelector = {}
          tolerations = [
            {
              operator = "Exists"
              effect   = "NoSchedule"
            },
            {
              operator = "Exists"
              effect   = "NoExecute"
            }
          ]
        }

        # Kube-state-metrics for pod/deployment metrics
        kubeStateMetrics = {
          enabled = true
        }
      }

      # Network costs monitoring
      networkCosts = {
        enabled = true

        # Pod monitor for network metrics
        podMonitor = {
          enabled = true
        }

        # Node affinity
        nodeSelector = var.node_selector
        tolerations  = var.tolerations
      }

      # Grafana (optional, disable to save resources)
      grafana = {
        enabled = false  # Kubecost has built-in UI
      }

      # Ingress (disabled - use port-forward or LoadBalancer)
      ingress = {
        enabled = false
      }

      # Service configuration
      service = {
        type = "ClusterIP"  # Use kubectl port-forward
        port = 9090
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.kubecost,
    kubernetes_service_account.kubecost
  ]
}

# ConfigMap for AWS credentials (if using static credentials instead of IRSA)
# Note: IRSA is preferred, this is a fallback
resource "kubernetes_secret" "aws_credentials" {
  count = var.use_irsa ? 0 : 1

  metadata {
    name      = "kubecost-aws-credentials"
    namespace = kubernetes_namespace.kubecost.metadata[0].name
  }

  data = {
    "aws-access-key-id"     = var.aws_access_key_id
    "aws-secret-access-key" = var.aws_secret_access_key
  }

  type = "Opaque"
}
