# ROSA HCP — Microsoft Entra ID OIDC Identity Provider
#
# Provisions an Entra ID (Azure AD) app registration, admin security group,
# configures the ROSA built-in OAuth server with the OIDC IdP, creates the
# cluster-admin RBAC binding for the admin group, and optionally removes
# the kubeadmin credential so the cluster relies entirely on IdP auth.

# ---------------------------------------------------------------------------
# Data Sources
# ---------------------------------------------------------------------------

data "azuread_client_config" "current" {}

# ---------------------------------------------------------------------------
# 1. Entra ID — Application Registration (OIDC Relying Party)
# ---------------------------------------------------------------------------

resource "azuread_application" "rosa_oidc" {
  display_name     = "${var.cluster_name}-rosa-oidc"
  sign_in_audience = "AzureADMyOrg"

  group_membership_claims = ["SecurityGroup"]

  web {
    redirect_uris = [var.oauth_callback_url]

    implicit_grant {
      id_token_issuance_enabled = true
    }
  }

  optional_claims {
    id_token {
      name = "email"
    }
    id_token {
      name = "preferred_username"
    }
  }

  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph

    resource_access {
      id   = "37f7f235-527c-4136-accd-4a02d197296e" # openid
      type = "Scope"
    }
    resource_access {
      id   = "64a6cdd6-aab1-4aaf-94b8-3cc8405e90d0" # email
      type = "Scope"
    }
    resource_access {
      id   = "14dad69e-099b-42c9-810b-d002981feec1" # profile
      type = "Scope"
    }
    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d" # User.Read
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "rosa_oidc" {
  client_id = azuread_application.rosa_oidc.client_id
}

resource "azuread_application_password" "rosa_oidc" {
  application_id    = azuread_application.rosa_oidc.id
  display_name      = "${var.cluster_name}-rosa-oidc-secret"
  end_date_relative = "8760h" # 1 year
}

# ---------------------------------------------------------------------------
# 2. Entra ID — Admin Security Group
# ---------------------------------------------------------------------------

resource "azuread_group" "rosa_cluster_admins" {
  display_name     = var.admin_group_name
  security_enabled = true
  owners           = [data.azuread_client_config.current.object_id]
  description      = "Cluster-admin group for ROSA HCP cluster ${var.cluster_name}"
}

resource "azuread_group_member" "admin_members" {
  for_each = toset(var.admin_group_member_object_ids)

  group_object_id  = azuread_group.rosa_cluster_admins.object_id
  member_object_id = each.value
}

# ---------------------------------------------------------------------------
# 3. ROSA — OpenID Connect Identity Provider (built-in OAuth server)
# ---------------------------------------------------------------------------

resource "rhcs_identity_provider" "entra_oidc" {
  cluster = var.cluster_id
  name    = var.idp_name

  openid = {
    client_id     = azuread_application.rosa_oidc.client_id
    client_secret = azuread_application_password.rosa_oidc.value
    issuer        = "https://login.microsoftonline.com/${data.azuread_client_config.current.tenant_id}/v2.0"

    claims = {
      email              = ["email"]
      name               = ["name"]
      preferred_username = ["preferred_username"]
      groups             = ["groups"]
    }

    extra_scopes = ["email", "profile"]
  }

  mapping_method = "claim"
}

# ---------------------------------------------------------------------------
# 4. Kubernetes RBAC — bind the Entra admin group to cluster-admin
# ---------------------------------------------------------------------------

# OpenShift maps the OIDC "groups" claim values directly to group names.
# Entra ID emits group Object IDs in the claim, so the subject name must
# be the Object ID of the admin security group.

resource "kubernetes_cluster_role_binding" "entra_cluster_admins" {
  metadata {
    name = "entra-id-cluster-admins"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "Group"
    name      = azuread_group.rosa_cluster_admins.object_id
    api_group = "rbac.authorization.k8s.io"
  }

  depends_on = [rhcs_identity_provider.entra_oidc]
}
/*
# ---------------------------------------------------------------------------
# 5. Disable kubeadmin — remove the credential so only IdP auth is allowed
# ---------------------------------------------------------------------------

resource "null_resource" "disable_kubeadmin" {
  count = var.disable_kubeadmin ? 1 : 0

  triggers = {
    cluster_id = var.cluster_id
    idp_name   = var.idp_name
  }

  provisioner "local-exec" {
    command     = "oc delete secret kubeadmin -n kube-system --ignore-not-found"
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [
    rhcs_identity_provider.entra_oidc,
    kubernetes_cluster_role_binding.entra_cluster_admins,
  ]
}
*/