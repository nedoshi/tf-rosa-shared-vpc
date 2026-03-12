# ROSA HCP Cluster Automation

Terraform automation for Red Hat OpenShift Service on AWS (ROSA) with Hosted Control Plane (HCP).
Deploys a private ROSA HCP cluster with shared VPC, customer-managed KMS encryption, and
KMS-encrypted StorageClasses.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Shared VPC Account (aws.shared_vpc_account provider)               │
│                                                                     │
│  VPC ─── Public Subnet ─── NAT Gateway ─── Internet Gateway         │
│   │                                                                 │
│   ├── Private Subnet (AZ-a) ──┐                                     │
│   ├── Private Subnet (AZ-b) ──┼── ROSA Worker Nodes                 │
│   └── Private Subnet (AZ-c) ──┘                                     │
│                                                                     │
│  Route53 Private Hosted Zones:                                      │
│   ├── hypershift.local           (HCP internal)                     │
│   └── apps.<cluster>.hypershift.local  (ingress + DNS wildcard fix) │
│                                                                     │
│  IAM Roles: route53-role, vpc-endpoint-role                         │
│  VPC Endpoint: PrivateLink to HCP control plane                     │
├─────────────────────────────────────────────────────────────────────┤
│  Cluster Account (default aws provider)                             │
│                                                                     │
│  IAM Roles (rosa CLI):  account-roles, operator-roles, OIDC         │
│  KMS Key (Terraform):   etcd + node volume encryption               │
│  ROSA HCP Cluster:      private, 3 worker nodes (m5.xlarge)         │
└─────────────────────────────────────────────────────────────────────┘
```

For testing, both accounts can be the same AWS account.

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
├── main.tf                 # Module orchestration + DNS fix
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
Step 0: rosa CLI ──→ account-roles, OIDC config, operator-roles
                          │
Step 1: terraform  ──→ shared_vpc ──→ KMS ──→ cluster ──→ DNS fix
                          │
Step 2: oc login   ──→ bastion SSH tunnel (private cluster)
                          │
Step 3: terraform  ──→ post-install (StorageClasses)
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
# Output example: "OIDC Configuration ID: 2p09v0f9057umaeikp1v98ueshhmvlir"

# Get the installer role ARN
INSTALLER_ROLE_ARN=$(aws iam get-role \
  --role-name demo1-HCP-ROSA-Installer-Role \
  --query 'Role.Arn' --output text)

# Create operator roles
rosa create operator-roles --prefix demo1 --hosted-cp \
  --oidc-config-id <OIDC_CONFIG_ID> \
  --installer-role-arn $INSTALLER_ROLE_ARN \
  --mode auto -y

# Verify
rosa list account-roles | grep demo1
rosa list operator-roles | grep demo1
```

Update `oidc_config_id` in `environments/us-east-1/demo1.tfvars` with the ID from above.

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

```bash
cd terraform
export TF_VAR_rhcs_token=$(rosa token)

# Initialize
terraform init

# ALWAYS plan first — review the output before applying
terraform plan -var-file=environments/us-east-1/demo1.tfvars \
  -target=module.shared_vpc \
  -target=module.rosa_account_roles \
  -target=module.rosa_operator_roles \
  -target=module.rosa_kms \
  -target=module.rosa_cluster \
  -target=data.aws_vpc_endpoint.hcp \
  -target=aws_route53_record.ingress_wildcard

# Review the plan! Verify:
#   - 0 resources to destroy
#   - Cluster resource shows shared_vpc block with hosted zone IDs
#   - DNS wildcard record will be created
# Then apply:
terraform apply -var-file=environments/us-east-1/demo1.tfvars \
  -target=module.shared_vpc \
  -target=module.rosa_account_roles \
  -target=module.rosa_operator_roles \
  -target=module.rosa_kms \
  -target=module.rosa_cluster \
  -target=data.aws_vpc_endpoint.hcp \
  -target=aws_route53_record.ingress_wildcard
```

This takes ~20-30 minutes (cluster creation is the bottleneck).

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

## DNS Zone Shadowing Fix

ROSA HCP pre-creates the `apps.<cluster>.hypershift.local` Private Hosted Zone
but places the wildcard `*.apps.<cluster>.hypershift.local` CNAME in the parent
`<cluster>.hypershift.local` zone. Route53 resolves using the most-specific zone,
so the empty child zone shadows the parent's wildcard. Workers fail to resolve
`ignition-server.apps.<cluster>.hypershift.local` and get stuck in a boot loop.

The `aws_route53_record.ingress_wildcard` resource in `main.tf` fixes this
automatically by adding the wildcard CNAME directly in the ingress zone after
the cluster creates the VPC endpoint.

## Important: Always Plan Before Apply

**Never run `terraform apply -auto-approve` without reviewing the plan first.**
Terraform may mark resources as "tainted" from previous failed operations, which
causes them to be destroyed and recreated — including the cluster itself. Always:

1. Run `terraform plan` and review the output
2. Verify **0 resources to destroy** (unless you intend destruction)
3. Check that no resources show "tainted, so must be replaced"
4. Only then run `terraform apply`

If you see a tainted resource, untaint it first:
```bash
terraform untaint <resource_address>
```

## Notes

- Backend is **local** for testing. Uncomment S3 backend in `backend.tf` for production.
- Account roles, OIDC, and operator roles are created by `rosa` CLI. Terraform only looks them up via data sources.
- Post-install (Step 4) requires cluster API access via the SOCKS tunnel. It must be a separate apply stage.
- Provider versions are pinned to `~> major.minor` for compatibility with Terraform v1.5.x.
