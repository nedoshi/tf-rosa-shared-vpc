output "entra_app_client_id" {
  description = "Application (client) ID of the Entra ID OIDC app registration"
  value       = azuread_application.rosa_oidc.client_id
}

output "entra_app_object_id" {
  description = "Object ID of the Entra ID application"
  value       = azuread_application.rosa_oidc.object_id
}

output "admin_group_object_id" {
  description = "Object ID of the Entra ID admin security group"
  value       = azuread_group.rosa_cluster_admins.object_id
}

output "admin_group_display_name" {
  description = "Display name of the Entra ID admin security group"
  value       = azuread_group.rosa_cluster_admins.display_name
}

output "idp_name" {
  description = "Name of the OIDC identity provider configured on the ROSA cluster"
  value       = rhcs_identity_provider.entra_oidc.name
}

output "entra_tenant_id" {
  description = "Entra ID tenant ID used for the OIDC issuer"
  value       = data.azuread_client_config.current.tenant_id
}
