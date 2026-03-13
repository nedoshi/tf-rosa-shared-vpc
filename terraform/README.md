# ROSA HCP Cluster Automation

Terraform automation for Red Hat OpenShift Service on AWS (ROSA) with Hosted Control Plane (HCP).
Deploys a private ROSA HCP cluster with shared VPC, customer-managed KMS encryption, and
KMS-encrypted StorageClasses.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Shared VPC Account (aws.shared_vpc_account provider)                │
│                                                                      │
│  VPC ─── Public Subnet ─── NAT Gateway ─── Internet Gateway          │
│   │                                                                  │
│   ├── Private Subnet (AZ-a) ──┐                                      │
│   ├── Private Subnet (AZ-b) ──┼── ROSA Worker Nodes                  │
│   └── Private Subnet (AZ-c) ──┘                                      │
│                                                                      │
│  Route53 Private Hosted Zones:                                       │
│   ├── <cluster>.hypershift.local              (HCP internal)         │
│   └── rosa.<cluster>.<base_dns_domain>        (ingress)              │
│                                                                      │
│  IAM Roles (Terraform):                                              │
│   ├── route53-role       → ROSASharedVPCRoute53Policy                │
│   └── vpc-endpoint-role  → ROSASharedVPCEndpointPolicy               │
│  VPC Endpoint: PrivateLink to HCP control plane                      │
├──────────────────────────────────────────────────────────────────────┤
│  Cluster Account (default aws provider)                              │
│                                                                      │
│  IAM Roles (rosa CLI):  account-roles, operator-roles, OIDC          │
│  Inline policies (Terraform):                                        │
│   ├── control-plane-operator  → sts:AssumeRole shared VPC roles      │
│   └── ingress-operator        → sts:AssumeRole shared VPC roles      │
│  KMS Key (Terraform):   etcd + node volume encryption                │
│  ROSA HCP Cluster:      private, 3 worker nodes (m5.xlarge)          │
└──────────────────────────────────────────────────────────────────────┘
```

For testing, both accounts can be the same AWS account.
See [SHARED-VPC-IAM.md](SHARED-VPC-IAM.md) for a detailed IAM roles and trust policies reference.

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | >= 1.4.6 | Infrastructure provisioning |
| AWS CLI | v2 | AWS resource management |
| rosa CLI | >= 1.2.0 | ROSA role/OIDC creation |
| oc CLI | latest | Cluster access (post-install) |
| RHCS token | — | [Get token here](https://console.redhat.com/openshift/token) |

## Module Structure

```
terraform/
├── backend.tf              # Local backend (S3 commented out for prod)
├── providers.tf            # AWS (default + shared_vpc alias), RHCS, kubernetes, helm
├── variables.tf            # Root-level input variables
├── outputs.tf              # Cluster URLs, KMS ARN, cluster ID
├── main.tf                 # Module orchestration + operator IAM policies
├── modules/
│   ├── shared-vpc/         # VPC, subnets, NAT, hosted zones, IAM roles
│   ├── rosa-account-roles/ # Data source lookups (rosa CLI creates the actual roles)
│   ├── rosa-operator-roles/# Data source lookups for 8 operator roles
│   ├── rosa-kms/           # Customer-managed KMS key with ROSA operator policy
│   ├── rosa-cluster/       # rhcs_cluster_rosa_hcp resource
│   └── rosa-post-install/  # KMS-encrypted StorageClasses, demotes default gp3-csi
└── environments/
    ├── us-east-1/demo1.tfvars   # Shared VPC (same-account testing)
    ├── us-east-2/demo2.tfvars   # Shared VPC (cross-account)
    └── us-west-2/demo3.tfvars   # Shared VPC (cross-account)
```

## Dependency Chain

```
Step 0:  rosa CLI   ──→ account-roles, OIDC config, operator-roles, DNS domain
                           │
Step 1a: terraform  ──→ shared_vpc + operator IAM policies
                           │  (wait 15s for IAM propagation)
Step 1b: terraform  ──→ KMS ──→ cluster
                           │
Step 2:  oc login   ──→ bastion SSH tunnel (private cluster)
                           │
Step 3:  terraform  ──→ post-install (StorageClasses)
```

---

## Step-by-Step Testing Guide (demo1, us-east-1)

### Step 0: Create ROSA roles and OIDC config

These resources have Red Hat-managed policies that cannot be replicated in Terraform.
Terraform uses `data` sources to look them up.

```bash
# Login to ROSA
export RHCS_TOKEN="your-ocm-token"
rosa login --token=$RHCS_TOKEN

# Create account roles
rosa create account-roles --prefix demo1 --hosted-cp --mode auto -y

# Create OIDC config — save the ID from the output!
rosa create oidc-config --mode auto --managed=false -y
# Output example: "OIDC Configuration ID: 2pXXXXXXXXXXXXXXX"

# Get the installer role ARN
INSTALLER_ROLE_ARN=$(aws iam get-role \
  --role-name demo1-HCP-ROSA-Installer-Role \
  --query 'Role.Arn' --output text)

OIDC_CONFIG_ID="2pxxxxxxxxxxxxxxxx" # Output from above

# Create operator roles
rosa create operator-roles --prefix demo1 --hosted-cp \
  --oidc-config-id $OIDC_CONFIG_ID \
  --installer-role-arn $INSTALLER_ROLE_ARN \
  --mode auto -y

# Verify
rosa list account-roles | grep demo1
rosa list operator-roles | grep demo1
```

Update `oidc_config_id` in `environments/us-east-1/demo1.tfvars` with the ID from above.

### Step 0a: Reserve a DNS domain for HCP

Shared VPC HCP clusters **require** a `base_dns_domain`. The domain must be
registered with OCM under the `p3.openshiftapps.com` parent (the HCP architecture
parent for AWS). A classic ROSA domain (e.g. `p1.openshiftapps.com`) or an
unrelated custom domain will be rejected.

```bash
# Create an HCP-compatible DNS domain
rosa create dns-domain --hosted-cp

# List domains — copy the one under p3.openshiftapps.com
rosa list dns-domains
# Example output: xxxx.p3.openshiftapps.com
```

Update `base_dns_domain` in your tfvars:
```
base_dns_domain = "xxxx.p3.openshiftapps.com"
```

### Step 0b: Create IAM role for shared VPC (same-account testing)

When testing with a single AWS account, create a role that Terraform assumes
to simulate the cross-account shared VPC pattern:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws iam create-role --role-name ROSA-SharedVPC-TerraformRole \
  --assume-role-policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Principal\": { \"AWS\": \"arn:aws:iam::${ACCOUNT_ID}:root\" },
      \"Action\": \"sts:AssumeRole\"
    }]
  }"

aws iam attach-role-policy --role-name ROSA-SharedVPC-TerraformRole \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

Update `shared_vpc_role_arn` in `demo1.tfvars`:
```
shared_vpc_role_arn = "arn:aws:iam::<ACCOUNT_ID>:role/ROSA-SharedVPC-TerraformRole"
```

### Step 1: Deploy infrastructure + cluster

Deployment is split into two stages to allow IAM policy propagation before
the cluster creation validates role access.

```bash
cd terraform
export TF_VAR_rhcs_token=$(rosa token)

# Initialize
terraform init

# --- Stage 1a: VPC, hosted zones, IAM roles, operator policies ---
terraform apply -var-file=environments/us-east-1/demo1.tfvars \
  -target=module.shared_vpc \
  -target=aws_iam_role_policy.operator_assume_shared_vpc

# Wait for IAM propagation (trust policies + inline policies)
sleep 15

# --- Stage 1b: Cluster ---
terraform apply -var-file=environments/us-east-1/demo1.tfvars \
  -target=module.rosa_account_roles \
  -target=module.rosa_operator_roles \
  -target=module.rosa_kms \
  -target=module.rosa_cluster
```

Stage 1b takes ~20-30 minutes (cluster creation is the bottleneck).

**Why two stages?** ROSA validates that all shared VPC IAM roles are
assumable before starting cluster creation. If the trust policy or operator
inline policy was just created in the same Terraform run, AWS IAM eventual
consistency may cause the validation to fail. The 15-second pause ensures
propagation.

### Step 2: Access the private cluster via bastion

The cluster API is private (not reachable from the internet). Set up an SSH
tunnel through a bastion host in the VPC.

```bash
# Find the VPC and public subnet
VPC_ID=$(terraform output -raw -state=terraform.tfstate 2>/dev/null || \
  aws ec2 describe-vpcs --filters "Name=tag:Name,Values=demo1-shared-vpc" \
  --query "Vpcs[0].VpcId" --output text)

PUBLIC_SUBNET=$(aws ec2 describe-subnets --filters \
  "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
  --query "Subnets[0].SubnetId" --output text)

# Create key pair (skip if already exists)
aws ec2 create-key-pair --key-name demo1-bastion \
  --query "KeyMaterial" --output text > ~/.ssh/demo1-bastion.pem
chmod 600 ~/.ssh/demo1-bastion.pem

# Create security group
MY_IP=$(curl -s https://checkip.amazonaws.com)
SG_ID=$(aws ec2 create-security-group --group-name demo1-bastion-sg \
  --description "Bastion SSH" --vpc-id $VPC_ID --query "GroupId" --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 22 --cidr "${MY_IP}/32"

# Launch bastion (Amazon Linux 2023, t3.micro)
AMI_ID=$(aws ec2 describe-images --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

INSTANCE_ID=$(aws ec2 run-instances --image-id $AMI_ID --instance-type t3.micro \
  --key-name demo1-bastion --subnet-id $PUBLIC_SUBNET \
  --security-group-ids $SG_ID --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=demo1-bastion}]" \
  --query "Instances[0].InstanceId" --output text)

# Wait for it to be running
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
BASTION_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
echo "Bastion IP: $BASTION_IP"

# Start SOCKS proxy (runs in background)
ssh -o StrictHostKeyChecking=no -i ~/.ssh/demo1-bastion.pem \
  -D 1080 -f -N ec2-user@$BASTION_IP
```

### Step 3: Log in to the cluster

```bash
# Create cluster admin
rosa create admin --cluster demo1
# Save the password from the output!

# Wait ~1-2 minutes for the admin to propagate, then:
HTTPS_PROXY=socks5://localhost:1080 oc login \
  https://api.demo1.<domain>.openshiftapps.com:443 \
  --username cluster-admin --password <PASSWORD> \
  --insecure-skip-tls-verify

# Verify
HTTPS_PROXY=socks5://localhost:1080 oc get nodes
HTTPS_PROXY=socks5://localhost:1080 oc get clusterversion
```

### Step 4: Apply post-install (StorageClasses)

```bash
cd terraform
export TF_VAR_rhcs_token=$(rosa token)
export HTTPS_PROXY=socks5://localhost:1080

# Plan first!
terraform plan -var-file=environments/us-east-1/demo1.tfvars \
  -target=module.rosa_post_install

# Review: should show 2 StorageClasses to create + 1 null_resource
# NO cluster resources should be destroyed/replaced
terraform apply -var-file=environments/us-east-1/demo1.tfvars \
  -target=module.rosa_post_install

# Verify
HTTPS_PROXY=socks5://localhost:1080 oc get storageclass
```

Expected StorageClasses after post-install:

| Name | Provisioner | Reclaim | Default | KMS Encrypted |
|------|-------------|---------|---------|---------------|
| gp3-csi-kms | ebs.csi.aws.com | Delete | Yes | Yes |
| gp3-csi-kms-retain | ebs.csi.aws.com | Retain | No | Yes |
| gp3-csi | ebs.csi.aws.com | Delete | No (demoted) | No |
| gp2-csi | ebs.csi.aws.com | Delete | No | No |

---

## Cleanup

```bash
cd terraform
export TF_VAR_rhcs_token=$(rosa token)
export HTTPS_PROXY=socks5://localhost:1080

# Destroy in reverse order
terraform destroy -var-file=environments/us-east-1/demo1.tfvars

# Terminate bastion
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
aws ec2 delete-security-group --group-id $SG_ID
aws ec2 delete-key-pair --key-name demo1-bastion
rm -f ~/.ssh/demo1-bastion.pem

# Clean up rosa CLI resources
rosa delete operator-roles --prefix demo1 --mode auto -y
rosa delete oidc-config --oidc-config-id <OIDC_CONFIG_ID> --mode auto -y
rosa delete account-roles --prefix demo1 --mode auto -y

# Clean up the testing IAM role
aws iam detach-role-policy --role-name ROSA-SharedVPC-TerraformRole \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws iam delete-role --role-name ROSA-SharedVPC-TerraformRole
```

## Outputs

| Output | Description |
|--------|-------------|
| cluster_id | ROSA cluster ID |
| cluster_api_url | Cluster API endpoint |
| cluster_console_url | Web console URL |
| kms_key_arn | Customer-managed KMS key ARN |
| oidc_config_id | OIDC configuration ID |

## DNS Wildcard Record

With the correct hosted zone naming (`rosa.<cluster>.<base_domain>` for ingress),
ROSA HCP automatically creates the `*.apps` wildcard CNAME record in the ingress
zone during cluster creation. No manual DNS fix is required.

## Notes

- Backend is **local** for testing. Uncomment S3 backend in `backend.tf` for production.
- Account roles, OIDC, and operator roles are created by `rosa` CLI. Terraform only looks them up via data sources.
- Post-install (Step 4) requires cluster API access via the SOCKS tunnel. It must be a separate apply stage.
- Provider versions are pinned to `~> major.minor` for compatibility with Terraform v1.5.x.

## Shared VPC IAM Reference

See [SHARED-VPC-IAM.md](SHARED-VPC-IAM.md) for a complete reference of all
IAM roles, trust policies, permissions policies, and hosted zone naming
conventions required for ROSA HCP shared VPC deployments.

## DNS Domain Compatibility

ROSA HCP clusters on AWS use `p3.openshiftapps.com` as their architecture parent
domain. The `base_dns_domain` (mandatory for shared VPC clusters) must be a
subdomain reserved under this parent via `rosa create dns-domain --hosted-cp`.


### Hosted Zone Naming

ROSA HCP validates that the private hosted zone names match the cluster's domain
structure. The required pattern is:

| Zone | Name pattern | Example |
|------|-------------|---------|
| HCP internal | `<cluster_name>.hypershift.local` | `demo1.hypershift.local` |
| Ingress | `rosa.<cluster_name>.<base_dns_domain>` | `rosa.demo1.5lqd.p3.openshiftapps.com` |
