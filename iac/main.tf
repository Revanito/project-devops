# Le resource group est LU (data), il n'est PAS créé ici.
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

data "azurerm_client_config" "current" {}

resource "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  location            = data.azurerm_resource_group.this.location
  resource_group_name = data.azurerm_resource_group.this.name
  dns_prefix          = var.cluster_name
  sku_tier            = "Free" # control plane managé, non facturé (sans SLA)

  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = var.vm_size
    # Pour la science, on essaie avec la valeur "tempdefault" pour le passer en Standard_B2ms au lieu de B2s
    # Role necessaire (que nous n'avons pas) : Delete: unexpected status 403 (403 Forbidden) with error: AuthorizationFailed
    temporary_name_for_rotation = "tempdefault"
    # Reprend la valeur par défaut d'AKS : sans ce bloc, azurerm 4.x voudrait
    # le SUPPRIMER à un plan ultérieur -> diff parasite sur le cluster.
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned" # identité managée : aucun secret à gérer
  }

  # Réseau : moteur de NetworkPolicy activé dès la création (sinon les
  # NetworkPolicy sont acceptées mais SANS EFFET).
  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
  }

  # Le cluster hérite des étiquettes du resource group (conformité policy école),
  # puis ajoute le tag "user" obligatoire pour ce projet.
  tags = merge(data.azurerm_resource_group.this.tags, { user = var.myuid })

  # Certaines étiquettes sont (re)mutées par l'Azure Policy de l'école après création :
  # on ignore leurs dérives pour garder des plans STABLES.
  lifecycle {
    ignore_changes = [tags]
  }
}

# Identité utilisée par le job "deploy" du pipeline GitHub Actions pour s'authentifier
# Azure via OIDC = pas de secret
# on passe par une Managed Identity
resource "azurerm_user_assigned_identity" "ci" {
  name                = "project-devops-ci-identity"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  tags                = merge(data.azurerm_resource_group.this.tags, { user = var.myuid })

  lifecycle {
    ignore_changes = [tags]
  }
}

# Droit nécessaire pour que le pipeline puisse récupérer les credentials AKS
# (az aks get-credentials) et déployer (kubectl apply).
resource "azurerm_role_assignment" "ci_contributor" {
  scope                = data.azurerm_resource_group.this.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.ci.principal_id
}

# Lien de confiance OIDC entre GitHub Actions et cette identité.
# resource_group_name > deprecated dans terraform avec l'assigned identity, changement // aussi "parent_id" deprecated, putain
resource "azurerm_federated_identity_credential" "ci_github" {
  name                       = "github-actions-main-branch"
  user_assigned_identity_id  = azurerm_user_assigned_identity.ci.id
  audience                   = ["api://AzureADTokenExchange"]
  issuer                     = "https://token.actions.githubusercontent.com/"
  subject                    = "repo:Revanito@100203166/project-devops@1344687975:ref:refs/heads/main"
}
# Source https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/managed_service_identity
# Source https://learn.microsoft.com/en-us/azure/developer/terraform/authenticate-to-azure-with-managed-identity-for-azure-services
