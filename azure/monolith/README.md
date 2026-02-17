# AKS monolith deployment scripts

This folder containing scripts and Kubernetes resources configurations to run ThingsBoard in Monolith mode on Azure AKS cluster.

You can find the deployment guide by the [**link**](https://thingsboard.io/docs/user-guide/install/pe/cluster/azure-monolith-setup/).

Notes:
- `k8s-deploy-resources.sh` preserves existing `tb-node-db-config` by default.
- To overwrite DB settings from `tb-node-db-configmap.yml`, run with `FORCE_DB_CONFIG_APPLY=true`.
