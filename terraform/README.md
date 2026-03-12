# ROSA HCP Cluster Automation

Terraform automation for Red Hat OpenShift Service on AWS (ROSA) with Hosted Control Plane (HCP) clusters. Supports shared VPC and customer-managed KMS.

Demo clusters: **demo1** (us-east-1), **demo2** (us-east-2), **demo3** (us-west-2).

## Prerequisites

- **Terraform** >= 1.4.6
- **AWS credentials** configured for the cluster account
- **RHCS token** — Create at [Red Hat Hybrid Cloud Console](https://console.redhat.com/openshift/token)
- **rosa CLI** >= 1.2.0
- **oc CLI** — OpenShift client for cluster access

## Pre-Terraform Steps (required)

Before running `terraform apply`, you must create the ROSA account roles, OIDC config, and operator roles using the `rosa` CLI. These resources have Red Hat-managed policies that cannot be replicated in Terraform.

```bash
# 1. Login to ROSA
rosa login --token=$RHCS_TOKEN

# 2. Create account roles (installer, support, worker)
rosa create account-roles --prefix demo1 --hosted-cp --mode auto -y

# 3. Create OIDC config (save the ID from the output!)
rosa create oidc-config --mode auto --managed=false -y
# Output: "? OIDC Configuration ID: 2abcdef1234567890abcdef123456789"
# Copy this ID into your .tfvars file as oidc_config_id

# 4. Get the installer role ARN
INSTALLER_ROLE_ARN=$(aws iam get-role --role-name demo1-HCP-ROSA-Installer-Role --query 'Role.Arn' --output text)

# 5. Create operator roles
rosa create operator-roles --prefix demo1 --hosted-cp \
  --oidc-config-id <OIDC_CONFIG_ID_FROM_STEP_3> \
  --installer-role-arn $INSTALLER_ROLE_ARN \
  --mode auto -y

# 6. Verify all roles exist
rosa list account-roles | grep demo1
rosa list operator-roles | grep demo1
```

After these steps, update your `.tfvars` file with the `oidc_config_id` from step 3.

## Two Deployment Modes

| Mode | `shared_vpc_role_arn` | `subnet_ids` | What happens |
|------|-----------------------|--------------|--------------|
| **Shared VPC** | Set to the assume-role ARN | `[]` (ignored) | Terraform creates VPC, subnets, hosted zones, DNS records |
| **Single-account / BYO VPC** | `""` (empty) | Provide existing subnet IDs | Shared-VPC module is skipped entirely |

## Module Structure

```
terraform/
├── backend.tf           # Local backend (S3 backend commented for production)
├── providers.tf         # AWS (default + shared_vpc alias), RHCS, kubernetes, helm
├── variables.tf         # Root-level variables
├── outputs.tf           # Cluster URLs, KMS ARN, cluster ID, OIDC config ID
├── main.tf              # Module orchestration, dependency chain, DNS fix
├── modules/
│   ├── shared-vpc/            # VPC, subnets, hosted zones, RAM share, IAM roles
│   ├── rosa-account-roles/    # Data source lookups for roles created by `rosa` CLI
│   ├── rosa-operator-roles/   # Data source lookups for operator roles created by `rosa` CLI
│   ├── rosa-kms/              # Customer-managed KMS key with ROSA operator policy
│   ├── rosa-cluster/          # rhcs_cluster_rosa_hcp with shared VPC + CMK
│   └── rosa-post-install/     # StorageClasses (gp3-csi-kms, gp3-csi-kms-retain)
└── environments/
    ├── us-east-1/
    │   └── demo1.tfvars       # Single-account mode (shared_vpc_role_arn = "")
    ├── us-east-2/
    │   └── demo2.tfvars       # Shared VPC mode
    └── us-west-2/
        └── demo3.tfvars       # Shared VPC mode
```

## Dependency Chain

```
rosa CLI (account-roles, oidc, operator-roles)
         ↓
shared_vpc (conditional) → kms → cluster → DNS fix → post_install
```

## Usage

### 1. Run pre-terraform steps (see above)

### 2. Set variables

```bash
export TF_VAR_rhcs_token="your-ocm-token"
```

Update `oidc_config_id` in your `.tfvars` file.

### 3. Initialize and apply

```bash
cd terraform
terraform init

# Plan
terraform plan -var-file=environments/us-east-1/demo1.tfvars

# Apply — Stage 1: infrastructure + cluster
terraform apply -var-file=environments/us-east-1/demo1.tfvars \
  -target=module.shared_vpc \
  -target=module.rosa_account_roles \
  -target=module.rosa_operator_roles \
  -target=module.rosa_kms \
  -target=module.rosa_cluster

# Apply — Stage 2: post-install (after oc login)
terraform apply -var-file=environments/us-east-1/demo1.tfvars
```

### Per-Environment Deployment

| Cluster | Region    | Command |
|---------|-----------|---------|
| demo1   | us-east-1 | `terraform apply -var-file=environments/us-east-1/demo1.tfvars` |
| demo2   | us-east-2 | `terraform apply -var-file=environments/us-east-2/demo2.tfvars` |
| demo3   | us-west-2 | `terraform apply -var-file=environments/us-west-2/demo3.tfvars` |

## Outputs

| Output              | Description                    |
|---------------------|--------------------------------|
| cluster_id          | ROSA cluster ID                |
| cluster_api_url     | Cluster API endpoint           |
| cluster_console_url | Web console URL                |
| kms_key_arn         | Customer-managed KMS key ARN   |
| oidc_config_id      | OIDC configuration ID          |

## DNS Zone Shadowing Fix (Shared VPC)

When using shared VPC, Terraform pre-creates the `apps.<cluster>.hypershift.local` Private Hosted Zone and passes it to ROSA HCP. However, ROSA HCP places the wildcard `*.apps.<cluster>.hypershift.local` CNAME in the parent `<cluster>.hypershift.local` zone. Route53 uses the most-specific zone for lookups, so the empty child zone shadows the parent's wildcard, causing worker nodes to fail DNS resolution during ignition.

The `aws_route53_record.ingress_wildcard` resource in `main.tf` automatically fixes this by adding the wildcard CNAME directly in the ingress zone after the cluster and VPC endpoint are created.

## Notes

- Backend is set to **local** for testing. Uncomment the S3 backend in `backend.tf` for production use.
- Account roles, OIDC config, and operator roles are created by `rosa` CLI, not Terraform. Terraform only looks them up via data sources.
- Post-install requires cluster API access; run `oc login` after cluster creation before Stage 2.
- **Shared VPC module is conditional** — it only runs when `shared_vpc_role_arn` is set. For single-account testing, set `shared_vpc_role_arn = ""` and provide `subnet_ids` with your existing private subnets.
