# ROSA HCP Cluster Automation - Root Module
# Orchestrates shared VPC -> account roles -> operator roles -> KMS -> cluster

locals {
  operator_role_arns = module.rosa_operator_roles.operator_role_arns
  is_shared_vpc      = var.shared_vpc_role_arn != ""
}

# 1. VPC infrastructure — always creates VPC, subnets, NAT, hosted zones, IAM roles
module "shared_vpc" {
  source = "./modules/shared-vpc"

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
  subnet_ids            = module.shared_vpc.private_subnet_ids
  machine_cidr          = var.vpc_cidr
  kms_key_arn           = module.rosa_kms.kms_key_arn
  etcd_kms_key_arn      = module.rosa_kms.kms_key_arn
  oidc_config_id        = module.rosa_account_roles.oidc_config_id
  operator_roles_prefix = var.operator_roles_prefix
  installer_role_arn    = module.rosa_account_roles.installer_role_arn
  support_role_arn      = module.rosa_account_roles.support_role_arn
  worker_role_arn       = module.rosa_account_roles.worker_role_arn

  base_dns_domain       = local.is_shared_vpc ? var.base_dns_domain : ""
  hcp_internal_hz_id    = local.is_shared_vpc ? module.shared_vpc.hcp_internal_hosted_zone_id : null
  ingress_hz_id         = local.is_shared_vpc ? module.shared_vpc.ingress_hosted_zone_id : null
  vpc_endpoint_role_arn = local.is_shared_vpc ? module.shared_vpc.vpc_endpoint_role_arn : null
  route53_role_arn      = local.is_shared_vpc ? module.shared_vpc.route53_role_arn : null

  external_auth_providers_enabled = var.external_auth_providers_enabled

  depends_on = [
    module.shared_vpc,
    module.rosa_account_roles,
    module.rosa_operator_roles,
    module.rosa_kms
  ]
}

# -----------------------------------------------------------------------------
<<<<<<< HEAD
# 6. Post-cluster DNS fix for shared VPC
=======
# 6. Post-cluster DNS fix
# ROSA HCP places the wildcard *.apps record in the parent zone
# (cluster.hypershift.local) instead of the dedicated ingress zone
# (apps.cluster.hypershift.local). The more-specific ingress zone shadows
# the parent wildcard, breaking DNS resolution for worker ignition.
# This resource adds the wildcard directly in the ingress zone.
>>>>>>> 156e1f1 (terraform module)
# -----------------------------------------------------------------------------
data "aws_vpc_endpoint" "hcp" {
  vpc_id = module.shared_vpc.vpc_id

  filter {
    name   = "vpc-endpoint-type"
    values = ["Interface"]
  }

  filter {
    name   = "vpc-endpoint-state"
    values = ["available"]
  }

  filter {
    name   = "tag:red-hat-managed"
    values = ["true"]
  }

  depends_on = [module.rosa_cluster]
}

resource "aws_route53_record" "ingress_wildcard" {
  provider = aws.shared_vpc_account
  zone_id  = module.shared_vpc.ingress_hosted_zone_id
  name     = "*.apps.${var.cluster_name}.hypershift.local"
  type     = "CNAME"
  ttl      = 300
  records  = [data.aws_vpc_endpoint.hcp.dns_entry[0].dns_name]

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
