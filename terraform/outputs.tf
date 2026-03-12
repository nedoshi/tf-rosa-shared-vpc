output "cluster_api_url" {
  description = "API URL of the ROSA HCP cluster"
  value       = module.rosa_cluster.cluster_api_url
}

output "cluster_console_url" {
  description = "Web console URL of the ROSA HCP cluster"
  value       = module.rosa_cluster.cluster_console_url
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for cluster encryption"
  value       = module.rosa_kms.kms_key_arn
}

output "cluster_id" {
  description = "ID of the ROSA HCP cluster"
  value       = module.rosa_cluster.cluster_id
}

output "oidc_config_id" {
  description = "OIDC configuration ID"
  value       = module.rosa_account_roles.oidc_config_id
}
