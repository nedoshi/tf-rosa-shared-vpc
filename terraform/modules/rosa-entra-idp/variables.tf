variable "cluster_id" {
  description = "ROSA HCP cluster ID (from rhcs_cluster_rosa_hcp)"
  type        = string
}

variable "cluster_name" {
  description = "ROSA HCP cluster name, used for naming Entra ID resources"
  type        = string
}

variable "oauth_callback_url" {
  description = "Full OAuth callback URL: https://oauth.<apps_domain>/oauth2callback/<idp_name>"
  type        = string
}

variable "idp_name" {
  description = "Display name for the identity provider in ROSA"
  type        = string
  default     = "Entra-ID"
}

variable "admin_group_name" {
  description = "Display name for the Entra ID security group that maps to cluster-admin"
  type        = string
}

variable "admin_group_member_object_ids" {
  description = "Object IDs of Entra ID users/principals to add to the admin group"
  type        = list(string)
  default     = []
}

variable "disable_kubeadmin" {
  description = "Delete the kubeadmin secret after the IdP is configured"
  type        = bool
  default     = true
}
