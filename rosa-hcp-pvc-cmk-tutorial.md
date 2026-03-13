# Detailed Tutorial: PVC Behavior with CMK-Encrypted EBS Storage on ROSA HCP

## Overview

When deploying ROSA HCP (Hosted Control Plane) clusters with customer-managed KMS (CMK) keys, understanding how Persistent Volume Claims (PVCs) interact with encrypted EBS storage is critical for compliance and data security.

---

## 1. Understanding PVC Behavior with CMK-Encrypted EBS

### How PVCs Work with KMS Encryption

```
┌─────────────────────────────────────────────────────────────────┐
│                        ROSA HCP Cluster                          │
│                                                                  │
│  PVC Request → StorageClass → EBS Volume → KMS CMK → EBS Key    │
│                                                                  │
│  1. User creates PVC                                             │
│  2. PVC references StorageClass with KMS key ID                 │
│  3. Dynamic provisioning creates EBS volume                     │
│  4. EBS volume is encrypted using your CMK                      │
│  5. EBS service creates grants in KMS for volume operations     │
└─────────────────────────────────────────────────────────────────┘
```

### Key Behaviors to Expect

| Aspect | Behavior |
|--------|----------|
| **Volume Creation** | EBS volumes are created encrypted with your CMK |
| **KMS Grants** | EBS service creates KMS grants for each volume (visible in KMS console) |
| **Snapshot Support** | Snapshots inherit encryption from source volume |
| **Cross-AZ** | Encrypted volumes can be attached across AZs in same region |
| **Key Rotation** | Existing volumes continue using original key material |

### Important Notes

- **KMS Key Policy**: Must allow `rosa` service role and `ec2` service principal
- **Key Permissions**: Requires `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey`, `kms:CreateGrant`
- **VWCS (Via AWS KMS)**: Requires additional setup for key grants

---

## 2. Creating a Customer-Managed Key in AWS KMS

### Step 1: Create the CMK

```bash
# Create a symmetric CMK for EBS encryption
aws kms create-key \
  --description "ROSA HCP EBS Encryption Key" \
  --key-usage ENCRYPT_DECRYPT \
  --origin AWS_KMS \
  --tags Key=Purpose,Value=ROSA-EBS-Encryption
```

### Step 2: Configure Key Policy

Create a policy file `kms-key-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Id": "ROSA-EBS-Key-Policy",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<ACCOUNT-ID>:root"
      },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "Allow EBS Service",
      "Effect": "Allow",
      "Principal": {
        "Service": "ebs.amazonaws.com"
      },
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey*",
        "kms:CreateGrant",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Allow ROSA Service Role",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<ACCOUNT-ID>:role/ROSAebsCSIDriverRole"
      },
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey*",
        "kms:CreateGrant",
        "kms:DescribeKey"
      ],
      "Resource": "*"
    }
  ]
}
```

Apply the policy:

```bash
aws kms put-key-policy \
  --key-id <YOUR-CMK-ID> \
  --policy file://kms-key-policy.json
```

---

## 3. Creating ROSA HCP Cluster with CMK

### Prerequisites

```bash
# Verify ROSA CLI
rosa version

# Verify AWS credentials
aws sts get-caller-identity

# List available KMS keys
aws kms list-keys
```

### Create HCP Cluster with KMS Key

```bash
rosa create cluster \
  --cluster-name <cluster-name> \
  --role-arn arn:aws:iam::<ACCOUNT-ID>:role/ROSAebsCSIDriverRole \
  --worker-iam-role arn:aws:iam::<ACCOUNT-ID>:role/WorkerNodeRole \
  --kms-key-arn arn:aws:kms:<region>:<ACCOUNT-ID>:key/<KEY-ID> \
  --compute-encryption-provider aws.kms \
  --hosted-cp \
  --region <region>
```

### Key Parameters Explained

| Parameter | Description |
|-----------|-------------|
| `--kms-key-arn` | ARN of your customer-managed key |
| `--compute-encryption-provider` | Set to `aws.kms` for KMS encryption |
| `--hosted-cp` | Specifies Hosted Control Plane |
| `--worker-iam-role` | IAM role for worker nodes |

---

## 4. Creating StorageClass for KMS-Encrypted EBS

### Default StorageClass (Auto-created by ROSA)

ROSA HCP automatically creates a default `gp3-encrypted` StorageClass when KMS is configured.

```bash
# Verify StorageClasses
oc get storageclass

# Expected output:
# NAME                PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
# gp3-encrypted       ebs.csi.k8s.aws         Delete          WaitForFirstConsumer   true                   5m
```

### Describe the StorageClass

```bash
oc describe storageclass gp3-encrypted
```

Expected output should show:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-encrypted
provisioner: ebs.csi.k8s.aws
parameters:
  type: gp3
  encrypted: "true"
  kmsKeyId: arn:aws:kms:<region>:<account-id>:key/<key-id>
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
```

### Creating Custom StorageClass

If you need a custom StorageClass:

```yaml
# ebs-kms-storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-kms-custom
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: ebs.csi.k8s.aws
parameters:
  type: gp3
  encrypted: "true"
  kmsKeyId: arn:aws:kms:<region>:<account-id>:key/<key-id>
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain
```

Apply:

```bash
oc apply -f ebs-kms-storageclass.yaml
```

---

## 5. Creating PVCs with KMS-Encrypted Storage

### Basic PVC Example

```yaml
# pvc-kms-encrypted.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: kms-encrypted-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: gp3-encrypted
```

Apply:

```bash
oc apply -f pvc-kms-encrypted.yaml
```

### Verify PVC and PV

```bash
# Check PVC status
oc get pvc kms-encrypted-pvc

# Check PV details
oc get pv

# Describe PV to see encryption details
oc describe pv <pv-name>
```

Expected PV output shows encryption:

```yaml
spec:
  capacity:
    storage: 10Gi
  csi:
    driver: ebs.csi.k8s.aws
    fsType: ext4
    volumeHandle: vol-0abc123def456
    volumeAttribute:
      encrypted: "true"
      kmsKeyId: arn:aws:kms:...
  storageClassName: gp3-encrypted
  volumeMode: Filesystem
```

---

## 6. Using Encrypted PVC in a Pod

```yaml
# pod-with-encrypted-pvc.yaml
apiVersion: v1
kind: Pod
metadata:
  name: app-with-encrypted-storage
  namespace: default
spec:
  containers:
  - name: app
    image: nginx:latest
    volumeMounts:
    - name: encrypted-storage
      mountPath: /data
  volumes:
  - name: encrypted-storage
    persistentVolumeClaim:
      claimName: kms-encrypted-pvc
```

Apply:

```bash
oc apply -f pod-with-encrypted-pvc.yaml
```

---

## 7. Verification and Troubleshooting

### Verify EBS Volume Encryption

```bash
# Get volume ID from PV
VOLUME_ID=$(oc get pv -o jsonpath='{.items[*].spec.csi.volumeHandle}')

# Check EBS volume encryption status
aws ec2 describe-volumes \
  --volume-ids $VOLUME_ID \
  --query 'Volumes[0].{Encrypted:Encrypted,KmsKeyId:KmsKeyId}'
```

### Verify KMS Grants

```bash
# List KMS grants for your CMK
aws kms list-grants \
  --key-id <YOUR-CMK-ID> \
  --query 'Grants[*].{GranteePrincipal:GranteePrincipal,GrantingPrincipal:GrantingPrincipal,Operations:Operations}'
```

### Common Issues and Solutions

| Issue | Cause | Solution |
|-------|-------|----------|
| PVC stuck in Pending | StorageClass not found | `oc get storageclass` - verify name matches |
| Volume creation fails | KMS key policy missing | Add EBS service principal to key policy |
| Access denied | Missing kms:CreateGrant | Update key policy with CreateGrant permission |
| Cross-region error | KMS key region mismatch | KMS key must be in same region as cluster |

### Debug Commands

```bash
# Check events for PVC
oc describe pvc <pvc-name>

# Check CSI driver logs
oc logs -n openshift-cluster-csi-drivers -l app=ebs-csi-driver

# Check cluster events
oc get events --field-selector involvedObject.kind=PersistentVolumeClaim
```

---

## 8. Best Practices

### Key Management

- **Enable automatic key rotation** (annual)
- **Use key aliases** for easier management
- **Monitor KMS API calls** via CloudTrail
- **Set up key deletion waiting period** (7-30 days)

```bash
# Enable key rotation
aws kms enable-key-rotation --key-id <YOUR-CMK-ID>

# Create key alias
aws kms create-alias \
  --alias-name alias/rosa-ebs-key \
  --target-key-id <YOUR-CMK-ID>
```

### StorageClass Configuration

- Use `WaitForFirstConsumer` volume binding mode for HCP
- Set appropriate `reclaimPolicy` (Delete for dev, Retain for prod)
- Enable `allowVolumeExpansion` for flexibility

### Monitoring

```bash
# Monitor PVC storage usage
oc adm top storage

# Set up alerts for storage capacity
# Configure Prometheus alerts for PVC utilization
```

---

## 9. Cleanup Procedures

### Delete PVC

```bash
# Delete PVC (PV and EBS volume will be deleted if reclaimPolicy=Delete)
oc delete pvc kms-encrypted-pvc
```

### Verify EBS Volume Deletion

```bash
# Check if volume was deleted
aws ec2 describe-volumes --volume-ids <volume-id>
```

### Revoke KMS Grants (if needed)

```bash
# List grants
aws kms list-grants --key-id <CMK-ID>

# Retire specific grant
aws kms retire-grant \
  --key-id <CMK-ID> \
  --grant-token <grant-token>
```

---

## Summary

This tutorial covered:

1. **PVC behavior** with CMK-encrypted EBS - volumes are automatically encrypted
2. **KMS key setup** - proper policies for EBS and ROSA service roles
3. **Cluster creation** - using `--kms-key-arn` and `--compute-encryption-provider`
4. **StorageClass** - default `gp3-encrypted` or custom configurations
5. **PVC creation** - standard PVC manifests referencing encrypted StorageClass
6. **Verification** - commands to confirm encryption at rest
7. **Troubleshooting** - common issues and debugging commands
8. **Best practices** - key rotation, monitoring, and cleanup

For your upcoming cluster build, ensure the KMS key policy is configured before cluster creation, and verify the StorageClass is properly created with the correct KMS key ARN.
