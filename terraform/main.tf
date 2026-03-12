# ROSA HCP Cluster Automation - Root Module
# Orchestrates shared VPC -> account roles -> operator roles -> KMS -> cluster

locals {
  operator_role_arns = module.rosa_operator_roles.operator_role_arns
  is_shared_vpc      = var.shared_vpc_role_arn != ""
}

# 1. Shared VPC (in shared VPC account) - only created when using cross-account shared VPC
module "shared_vpc" {
  source = "./modules/shared-vpc"
  count  = local.is_shared_vpc ? 1 : 0

  providers = {
    aws = aws.shared_vpc_account
  }

  cluster_name       = var.cluster_name
  region             = var.region
  vpc_cidr           = var.vpc_cidr
  cluster_account_id = var.cluster_account_id
  availability_zones = var.availability_zones
  tags               = var.tags
}

# 2. Account roles — looks up roles created by `rosa create account-roles`
module "rosa_account_roles" {
  source = "./modules/rosa-account-roles"

  account_roles_prefix = var.account_roles_prefix
  oidc_config_id       = var.oidc_config_id
}

# 3. Operator roles — looks up roles created by `rosa create operator-roles`
module "rosa_operator_roles" {
  source = "./modules/rosa-operator-roles"

  operator_roles_prefix = var.operator_roles_prefix
}

# 4. KMS - depends on operator roles (needs operator role ARNs for policy)
module "rosa_kms" {
  source = "./modules/rosa-kms"

  cluster_name        = var.cluster_name
  aws_account_id      = var.cluster_account_id
  aws_region          = var.region
  account_roles_prefix = var.account_roles_prefix
  installer_role_arn  = module.rosa_account_roles.installer_role_arn
  support_role_arn    = module.rosa_account_roles.support_role_arn
  operator_role_arns = {
    capa_controller_manager         = local.operator_role_arns.capa_controller_manager
    control_plane_operator          = local.operator_role_arns.control_plane_operator
    kms_provider                     = local.operator_role_arns.kms_provider
    kube_controller_manager         = local.operator_role_arns.kube_controller_manager
    ebs_csi_driver                   = local.operator_role_arns.ebs_csi_driver
  }
  tags = var.tags

  depends_on = [module.rosa_operator_roles]
}

# 5. ROSA HCP Cluster - depends on shared VPC, account roles, operator roles, KMS
module "rosa_cluster" {
  source = "./modules/rosa-cluster"

  cluster_name          = var.cluster_name
  region                = var.region
  aws_account_id        = var.cluster_account_id
  openshift_version     = var.openshift_version
  availability_zones    = var.availability_zones
  subnet_ids            = local.is_shared_vpc ? module.shared_vpc[0].private_subnet_ids : var.subnet_ids
  machine_cidr          = var.vpc_cidr
  kms_key_arn           = module.rosa_kms.kms_key_arn
  etcd_kms_key_arn      = module.rosa_kms.kms_key_arn
  oidc_config_id        = module.rosa_account_roles.oidc_config_id
  operator_roles_prefix = var.operator_roles_prefix
  installer_role_arn    = module.rosa_account_roles.installer_role_arn
  support_role_arn      = module.rosa_account_roles.support_role_arn
  worker_role_arn       = module.rosa_account_roles.worker_role_arn

  base_dns_domain       = local.is_shared_vpc ? var.base_dns_domain : ""
  hcp_internal_hz_id    = local.is_shared_vpc ? module.shared_vpc[0].hcp_internal_hosted_zone_id : null
  ingress_hz_id         = local.is_shared_vpc ? module.shared_vpc[0].ingress_hosted_zone_id : null
  vpc_endpoint_role_arn = local.is_shared_vpc ? module.shared_vpc[0].vpc_endpoint_role_arn : null
  route53_role_arn      = local.is_shared_vpc ? module.shared_vpc[0].route53_role_arn : null

  external_auth_providers_enabled = var.external_auth_providers_enabled

  depends_on = [
    module.shared_vpc,
    module.rosa_account_roles,
    module.rosa_operator_roles,
    module.rosa_kms
  ]
}

# -----------------------------------------------------------------------------
# 6. Post-cluster DNS fix for shared VPC
# -----------------------------------------------------------------------------
data "aws_vpc_endpoint" "hcp" {
  count  = local.is_shared_vpc ? 1 : 0
  vpc_id = module.shared_vpc[0].vpc_id

  filter {
    name   = "vpc-endpoint-type"
    values = ["Interface"]
  }

  filter {
    name   = "vpc-endpoint-state"
    values = ["available"]
  }

  depends_on = [module.rosa_cluster]
}

resource "aws_route53_record" "ingress_wildcard" {
  count    = local.is_shared_vpc ? 1 : 0
  provider = aws.shared_vpc_account
  zone_id  = module.shared_vpc[0].ingress_hosted_zone_id
  name     = "*.apps.${var.cluster_name}.hypershift.local"
  type     = "CNAME"
  ttl      = 300
  records  = [data.aws_vpc_endpoint.hcp[0].dns_entry[0].dns_name]

  depends_on = [module.rosa_cluster]
}

# 7. Post-install (storage classes) - depends on cluster
module "rosa_post_install" {
  source = "./modules/rosa-post-install"

  cluster_name = var.cluster_name
  kms_key_arn  = module.rosa_kms.kms_key_arn

  storage_classes = {
    gp3-csi-kms        = { default = true, reclaim_policy = "Delete" }
    gp3-csi-kms-retain = { default = false, reclaim_policy = "Retain" }
  }

  depends_on = [module.rosa_cluster]
}
