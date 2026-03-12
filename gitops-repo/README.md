# ROSA HCP & ARO GitOps Repository

Helm-based GitOps structure for managing ROSA HCP (AWS) and ARO (Azure) OpenShift clusters with Red Hat Advanced Cluster Management (ACM) and Argo CD.

## Architecture Overview

- **ACM (Hub)**: Manages cluster lifecycle, policy enforcement, and placement decisions via ManagedClusterSets and Placements.
- **Argo CD**: Deploys Helm charts to managed clusters via ApplicationSets driven by ACM Placements.
- **Helm Charts**: Three chart families—cluster-baseline (all clusters), rosa-platform-config (ROSA only), aro-platform-config (ARO only).

## Directory Structure

```
gitops-repo/
├── bootstrap/
│   ├── acm/                    # ACM bootstrap: ClusterSets, bindings, placements, GitOps operator
│   └── argocd/                 # Argo CD bootstrap: AppProjects, ApplicationSets
├── charts/
│   ├── cluster-baseline/       # Common config: RBAC, monitoring, networking, security, namespaces
│   ├── rosa-platform-config/   # ROSA: StorageClass, OAuth, MachineConfig (journald)
│   └── aro-platform-config/    # ARO: StorageClass, OAuth
├── cluster-values/             # Per-cluster Helm values
│   ├── rosa/
│   └── aro/
├── policies/                   # ACM policies
│   ├── configuration/
│   ├── security/
│   └── compliance/
└── README.md
```

## How ApplicationSets Work

1. **platform-baseline-helm**: Targets all production clusters (`all-production` placement). Deploys `charts/cluster-baseline` with default values.
2. **platform-rosa-overlay-helm**: Targets ROSA production clusters (`rosa-production` placement). Deploys `charts/rosa-platform-config` with per-cluster values from `cluster-values/rosa/{{cluster-name}}.yaml`.
3. **platform-aro-overlay-helm**: Targets ARO production clusters (`aro-production` placement). Deploys `charts/aro-platform-config` with per-cluster values from `cluster-values/aro/{{cluster-name}}.yaml`.

Applications are configured for automated sync with prune and self-heal enabled.

## Adding a New Cluster

1. **Ensure the cluster is imported** into ACM and has the required labels (e.g. `platform: rosa` or `platform: aro`, `environment: production`).
2. **Create a values file** for the cluster:
   - ROSA: `cluster-values/rosa/<cluster-name>.yaml`
   - ARO: `cluster-values/aro/<cluster-name>.yaml`
3. **Populate cluster-specific values** such as:
   - `clusterName`
   - `storage.kmsKeyArn` (ROSA) or Azure storage settings (ARO)
   - `identityProvider.clientID`, `identityProvider.issuer`
4. Argo CD ApplicationSets will automatically pick up the cluster via placement and deploy using the new values file.

## Prerequisites

- **OpenShift GitOps (Argo CD)** installed via the GitOps operator subscription.
- **ACM** with managed clusters imported and labeled.
- **ManagedClusterSetBindings** binding rosa-clusters, aro-clusters, and production-clusters to `openshift-gitops` namespace.
- **Placements** (rosa-production, aro-production, all-production, rosa-eu) configured in `openshift-gitops`.
- Git repository access: `https://github.com/your-org/gitops-repo.git` (or update `repoURL` for your fork).

## Bootstrap Order

1. Apply ACM resources: cluster-sets → bindings → placements → gitops operator subscription.
2. Wait for OpenShift GitOps operator to install.
3. Apply Argo CD resources: appprojects → applicationsets.
