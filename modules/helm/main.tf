# Helm Module - DaskHub or Standalone Dask Gateway Deployment
# Based on daskhub.yaml configuration

# Full DaskHub (JupyterHub + Dask Gateway)
resource "helm_release" "daskhub" {
  count = var.enable_jupyterhub ? 1 : 0

  name             = "daskhub"
  repository       = "https://helm.dask.org"
  chart            = "daskhub"
  version          = "2024.1.1"
  namespace        = "daskhub"
  create_namespace = false  # Namespace created by kubernetes module
  timeout          = 600

  # JupyterHub Configuration
  values = [
    yamlencode({
      jupyterhub = {
        singleuser = {
          serviceAccountName = var.user_service_account
          startTimeout      = 600
          image = {
            name = var.singleuser_image_name
            tag  = var.singleuser_image_tag
          }
          cpu = {
            limit     = var.user_cpu_limit
            guarantee = var.user_cpu_guarantee
          }
          memory = {
            limit     = var.user_memory_limit
            guarantee = var.user_memory_guarantee
          }
          extraEnv = {
            DASK_GATEWAY__ADDRESS                 = "http://proxy-public/services/dask-gateway"
            DASK_GATEWAY__CLUSTER__OPTIONS__IMAGE = "{{JUPYTER_IMAGE_SPEC}}"
            SCRATCH_BUCKET                        = "s3://${var.s3_bucket}/$(JUPYTERHUB_USER)"
          }
          lifecycleHooks = var.lifecycle_hooks_enabled ? {
            postStart = {
              exec = {
                command = var.lifecycle_post_start_command
              }
            }
          } : null
          extraFiles = {
            "jupyter_notebook_config.json" = {
              mountPath = "/etc/jupyter/jupyter_notebook_config.json"
              data = {
                MappingKernelManager = {
                  cull_idle_timeout = var.kernel_cull_timeout
                  cull_interval     = 120
                  cull_connected    = true
                  cull_busy         = false
                }
              }
            }
          }
        }
        proxy = {
          https = {
            enabled = var.certificate_arn != ""
          }
          service = {
            type = "LoadBalancer"
          }
        }
        hub = {
          shutdownOnLogout = true
          config = merge(
            {
              Authenticator = {
                allow_all   = var.allow_all_users
                admin_users = var.admin_users
              }
            },
            var.cognito_enabled ? {
              GenericOAuthenticator = {
                client_id          = var.cognito_client_id
                oauth_callback_url = "https://${var.domain_name}/hub/oauth_callback"
                authorize_url      = var.cognito_authorize_url
                token_url          = var.cognito_token_url
                userdata_url       = var.cognito_userdata_url
                logout_redirect_url = var.cognito_logout_url
                login_service      = "AWS Cognito"
                username_claim     = "email"
              }
              JupyterHub = {
                authenticator_class = "generic-oauth"
              }
            } : {}
          )
        }
      }
      # Dask Gateway Configuration
      "dask-gateway" = {
        gateway = {
          backend = {
            scheduler = {
              extraPodConfig = {
                serviceAccountName = "user-sa"  # Use service account with S3 permissions
              }
            }
            worker = {
              extraPodConfig = {
                serviceAccountName = "user-sa"  # Use service account with S3 permissions
                nodeSelector = {
                  "eks.amazonaws.com/capacityType" = "SPOT"
                }
                tolerations = [
                  {
                    key      = "lifecycle"
                    operator = "Equal"
                    value    = "spot"
                    effect   = "NoExecute"
                  }
                ]
              }
            }
          }
          extraConfig = {
            optionHandler = <<-EOF
              from dask_gateway_server.options import Options, Float, String, Mapping
              def cluster_options(user):
                  def option_handler(options):
                      if ":" not in options.image:
                          raise ValueError("When specifying an image you must also provide a tag")
                      extra_annotations = {"hub.jupyter.org/username": user.name.replace('@', '_')}
                      extra_labels = extra_annotations
                      return {
                          "worker_cores": 0.88 * min(options.worker_cores / 2, 1),
                          "worker_cores_limit": options.worker_cores,
                          "worker_memory": "%fG" % (0.88 * options.worker_memory),
                          "worker_memory_limit": "%fG" % options.worker_memory,
                          "image": options.image,
                          "environment": options.environment,
                          "extra_annotations": extra_annotations,
                          "extra_labels": extra_labels,
                      }
                  return Options(
                      Float("worker_cores", ${var.dask_worker_cores_max}, min=1, max=${var.dask_worker_cores_max}),
                      Float("worker_memory", ${var.dask_worker_memory_max}, min=1, max=${var.dask_worker_memory_max}),
                      String("image", default="${var.singleuser_image_name}:${var.singleuser_image_tag}"),
                      Mapping("environment", {}),
                      handler=option_handler,
                  )
              c.Backend.cluster_options = cluster_options
              c.ClusterConfig.idle_timeout = ${var.server_cull_timeout}
              c.ClusterConfig.cluster_max_cores = ${var.dask_cluster_max_cores}
            EOF
          }
        }
      }
    })
  ]

  # Set client secret via set if Cognito enabled
  dynamic "set_sensitive" {
    for_each = var.cognito_enabled ? [1] : []
    content {
      name  = "jupyterhub.hub.config.GenericOAuthenticator.client_secret"
      value = var.cognito_client_secret
    }
  }
}

# Standalone Dask Gateway (no JupyterHub)
resource "helm_release" "dask_gateway_standalone" {
  count = var.enable_jupyterhub ? 0 : 1

  name             = "dask-gateway"
  repository       = "https://helm.dask.org"
  chart            = "dask-gateway"
  version          = "2024.1.0"
  namespace        = "daskhub"  # Keep same namespace for consistency
  create_namespace = false
  timeout          = 600

  values = [
    yamlencode({
      gateway = {
        # Expose Gateway via LoadBalancer for external access
        service = {
          type = "LoadBalancer"
          annotations = {
            "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb"
            "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
          }
        }
        # Authentication with API token
        auth = {
          type = "simple"  # Simple token-based auth
          simple = {
            password = random_password.gateway_token[0].result
          }
        }
        backend = {
          scheduler = {
            extraPodConfig = {
              serviceAccountName = "user-sa"
              # Scheduler runs on main nodes (no taint needed for single node group)
            }
          }
          worker = {
            extraPodConfig = {
              serviceAccountName = "user-sa"
              # Schedule workers on spot instances
              nodeSelector = {
                "eks.amazonaws.com/capacityType" = "SPOT"
              }
              tolerations = [
                {
                  key      = "lifecycle"
                  operator = "Equal"
                  value    = "spot"
                  effect   = "NoExecute"
                }
              ]
            }
          }
        }
        extraConfig = {
          clusterConfig = <<-EOF
            from dask_gateway_server.options import Options, Float, String, Mapping

            def cluster_options(user):
                def option_handler(options):
                    if ":" not in options.image:
                        raise ValueError("When specifying an image you must also provide a tag")
                    return {
                        "worker_cores": 0.88 * options.worker_cores,
                        "worker_cores_limit": options.worker_cores,
                        "worker_memory": "%fG" % (0.88 * options.worker_memory),
                        "worker_memory_limit": "%fG" % options.worker_memory,
                        "image": options.image,
                        "environment": options.environment,
                    }
                return Options(
                    Float("worker_cores", ${var.dask_worker_cores_max}, min=1, max=${var.dask_worker_cores_max}),
                    Float("worker_memory", ${var.dask_worker_memory_max}, min=1, max=${var.dask_worker_memory_max}),
                    String("image", default="${var.singleuser_image_name}:${var.singleuser_image_tag}"),
                    Mapping("environment", {}),
                    handler=option_handler,
                )

            c.Backend.cluster_options = cluster_options
            c.ClusterConfig.idle_timeout = ${var.server_cull_timeout}
            c.ClusterConfig.cluster_max_cores = ${var.dask_cluster_max_cores}
          EOF
        }
      }
    })
  ]
}

# Generate random API token for standalone Gateway
resource "random_password" "gateway_token" {
  count   = var.enable_jupyterhub ? 0 : 1
  length  = 32
  special = true
}

# Cluster Autoscaler
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.37.0"
  namespace  = "kube-system"
  timeout    = 300

  values = [
    yamlencode({
      autoDiscovery = {
        clusterName = var.cluster_name
      }
      awsRegion = var.region
      rbac = {
        serviceAccount = {
          create = true
          name   = "cluster-autoscaler"
          annotations = {
            "eks.amazonaws.com/role-arn" = var.cluster_autoscaler_role_arn
          }
        }
      }
      extraArgs = {
        balance-similar-node-groups = true
        skip-nodes-with-system-pods = false
      }
    })
  ]
}
