# Root Module Variables - ROSA HCP Automation

variable "cluster_name" {
  description = "Name of the ROSA HCP cluster (max 15 characters)"
  type        = string
}

variable "region" {
  description = "AWS region for the cluster"
  type        = string
}

variable "openshift_version" {
  description = "OpenShift version for the cluster"
  type        = string
  default     = "4.18.32"
}

variable "cluster_account_id" {
  description = "AWS account ID where the cluster will run"
  type        = string
}

variable "shared_vpc_account_id" {
  description = "AWS account ID of the shared VPC"
  type        = string
}

variable "account_roles_prefix" {
  description = "Prefix for account IAM roles"
  type        = string
}

variable "operator_roles_prefix" {
  description = "Prefix for operator IAM roles"
  type        = string
}

variable "oidc_config_id" {
  description = "OIDC config ID from `rosa create oidc-config` output"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "subnet_ids" {
  description = "Pre-existing private subnet IDs (required when shared_vpc_role_arn is empty)"
  type        = list(string)
  default     = []
}

variable "availability_zones" {
  description = "List of availability zones for the cluster"
  type        = list(string)
}

variable "tags" {
  description = "Tags applied to all objects."
  type        = map(string)
  default = {
    "cost-center"   = "468"
    "service-phase" = "lab"
    "app-code"      = "MOBB-001"
    "owner"         = "nedoshi@redhat.com"
  }
}

variable "rhcs_token" {
  description = "Red Hat Cloud Services (OCM) API token"
  type        = string
  sensitive   = true
}

variable "shared_vpc_role_arn" {
  description = "ARN of the role to assume in shared VPC account"
  type        = string
}

variable "base_dns_domain" {
  description = "Base DNS domain for the ROSA cluster (e.g. rosa.example.com)"
  type        = string
  default     = ""
}

variable "external_auth_providers_enabled" {
  description = "Enable external authentication providers (e.g. OIDC)"
  type        = bool
  default     = false
}
