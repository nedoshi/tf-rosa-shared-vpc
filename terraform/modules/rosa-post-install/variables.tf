# ROSA HCP Post-Install Module - Variables

variable "cluster_name" {
  description = "ROSA HCP cluster name"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the customer-managed KMS key for StorageClass encryption"
  type        = string
}

variable "storage_classes" {
  description = "Map of StorageClass names to configuration (default, reclaim_policy)"
  type = map(object({
    default        = bool
    reclaim_policy = string
  }))
  default = {
    gp3-csi-kms = {
      default        = true
      reclaim_policy = "Delete"
    }
    gp3-csi-kms-retain = {
      default        = false
      reclaim_policy = "Retain"
    }
  }
}
