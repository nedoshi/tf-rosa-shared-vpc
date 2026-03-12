# ROSA HCP Demo Cluster 3 — us-west-2 (Oregon)

cluster_name          = "demo3"
region                = "us-west-2"
openshift_version     = "4.18.32"
cluster_account_id    = "6XXXXXXXXXXX"
shared_vpc_account_id = "5XXXXXXXXXXX"
account_roles_prefix  = "demo3"
operator_roles_prefix = "demo3"
oidc_config_id        = ""  # Set from: rosa create oidc-config --mode auto --managed=false -y
vpc_cidr              = "10.222.0.0/24"
availability_zones    = ["us-west-2a", "us-west-2b", "us-west-2c"]
shared_vpc_role_arn   = "arn:aws:iam::5XXXXXXX:role/ROSA-SharedVPC-TerraformRole"
