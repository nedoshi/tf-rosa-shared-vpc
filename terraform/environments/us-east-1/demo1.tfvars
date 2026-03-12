# ROSA HCP Demo Cluster 1 — us-east-1 (Virginia)
# Non-shared-VPC mode: VPC/subnets are pre-existing, provide subnet_ids directly

cluster_name          = "demo1"
region                = "us-east-1"
openshift_version     = "4.21.0"
cluster_account_id    = "6XXXXXXXXXXX"
shared_vpc_account_id = "5XXXXXXXXXXX"
account_roles_prefix  = "demo1"
operator_roles_prefix = "demo1"
oidc_config_id        = ""  # Set from: rosa create oidc-config --mode auto --managed=false -y
vpc_cidr              = "10.220.228.0/24"
availability_zones    = ["us-east-1a", "us-east-1b", "us-east-1c"]
base_dns_domain       = "aws-na.mobb.cloud"
shared_vpc_role_arn   = ""

# When shared_vpc_role_arn is empty, the shared-vpc module is skipped.
# Provide pre-existing private subnet IDs for worker nodes.
subnet_ids = [
  "subnet-0e72efe20685233b7",  # us-east-1a
  "subnet-0ec13877c33e0b2a2",  # us-east-1b
  "subnet-0a6307d15c86998a2",  # us-east-1c
]
