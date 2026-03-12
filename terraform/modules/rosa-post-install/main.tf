# ROSA HCP Post-Install Module
# Creates KMS-encrypted StorageClasses and demotes default gp3-csi

# -----------------------------------------------------------------------------
# StorageClasses with KMS encryption
# -----------------------------------------------------------------------------
resource "kubernetes_storage_class_v1" "kms_encrypted" {
  for_each = var.storage_classes

  metadata {
    name = each.key
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = tostring(lookup(each.value, "default", false))
    }
    labels = {
      "managed-by" = "terraform"
      "cluster"    = var.cluster_name
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = lookup(each.value, "reclaim_policy", "Delete")
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion  = true

  parameters = merge(
    {
      type      = "gp3"
      encrypted = "true"
      kmsKeyId  = var.kms_key_arn
      fsType    = lookup(each.value, "fs_type", "ext4")
    },
    lookup(each.value, "iops", null) != null ? { iops = each.value.iops } : {},
    lookup(each.value, "throughput", null) != null ? { throughput = each.value.throughput } : {}
  )
}

# -----------------------------------------------------------------------------
# Demote gp3-csi as default StorageClass
# -----------------------------------------------------------------------------
resource "null_resource" "demote_default_storageclass" {
  depends_on = [kubernetes_storage_class_v1.kms_encrypted]

  provisioner "local-exec" {
    command = <<-EOT
      oc patch storageclass gp3-csi -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' 2>/dev/null || true
    EOT
  }

  triggers = {
    storage_classes = jsonencode(var.storage_classes)
  }
}
