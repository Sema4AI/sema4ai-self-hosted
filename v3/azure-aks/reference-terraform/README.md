# Sema4.ai self-hosted v3 — Azure AKS (reference infrastructure)

Terraform for running Sema4.ai v3 on **Azure Kubernetes Service**: the
cluster with its sandbox-capable node, and every Azure resource the
application depends on — PostgreSQL, blob storage, the Key Vault key, the
workload identity, the Entra ID app registrations used for sign-in, and the
Azure Front Door in front of it all. It also installs the sandbox runtime,
creates each deployment's database and roles, and renders a completed Helm
values file per deployment, so the one step left to you is installing the
application chart.

This is **reference infrastructure**: a working, minimal starting point.
Review it against your organization's standards (naming, tagging, network,
identity, compliance) and adapt it, or use it as a specification for your own
tooling. The deployment guide is the authoritative description of the
requirements and the install:

**📖 [Deploy on Azure AKS](https://sema4.ai/docs/v3/deploy/azure-aks)**

> **One deliberate difference from the guide: the public hostname.** The guide
> uses a hostname on your own domain, with TLS terminated in the cluster. This
> configuration serves each deployment at an **Azure-generated Front Door
> hostname** (`<deployment>-<hash>.z01.azurefd.net`) with a certificate
> Microsoft issues and rotates, so a proof of concept needs no domain, DNS
> record or certificate. [Ingress](#ingress) covers what that trades away.

## Shared responsibility

**Sema4.ai provides** the application as a Helm chart, this Terraform, and the
[sandbox runtime reference configuration](../../kata-containers/kata-values.yaml).

**You are responsible for**

- The Azure subscription and everything operational in it: Terraform state,
  backups, monitoring, cost, and security hardening.
- Installing the application with the rendered values files (step 2), and
  operating what Terraform installed: the sandbox runtime and the PostgreSQL
  server.
- Backing up the encryption keys in the rendered values files (step 4).
- An identity provider, unless you let this configuration create an Entra ID
  app registration per deployment.

## What this creates

| Resource | Role |
| --- | --- |
| **Resource groups** `rg-<infra_id>` and `rg-<infra_id>-aks-nodes` | The first holds everything below; AKS creates the second for the node VM, its disks, and the Gateway's load balancer. |
| **Virtual network** | A node subnet (with the `Microsoft.Storage` service endpoint) and a subnet delegated to PostgreSQL. |
| **AKS cluster** (Free tier) | Kubernetes 1.36+, workload identity, Azure CNI Overlay, and the Kubernetes Gateway API through the application routing add-on (`approuting-istio`). |
| **Node pool** (1 × `Standard_D32s_v5`) | 32 vCPU / 128 GiB with nested virtualization. Carries the whole application *and* every concurrent sandbox run. No autoscaler. |
| **PostgreSQL Flexible Server 18** | Shared by every deployment, with a database and three roles each. Private access only. |
| **Storage account + container** | The blob store: zone-redundant, shared by every deployment under its own key prefix, firewalled to the node subnet. |
| **Key Vault** | One RSA key per deployment: the chart's `infrastructure.azure.keyVaultKeyUrl`. |
| **User-assigned managed identity** | Storage Blob Data Contributor on the container and Key Vault Crypto User on the vault, federated with each deployment's service account. |
| **Entra ID app registrations** (optional) | The OIDC client for sign-in, one per deployment. |
| **Front Door** (Standard) | One endpoint per deployment: the public edge, and the only place TLS terminates. |
| **Network security group** | Admits only Front Door to the Gateway's load balancer. |
| **In the cluster** | One Gateway shared by every deployment, Kata Containers, and per deployment a namespace, a service account, and a Job that creates its database and roles. |
| **On disk** | `rendered/values-<deployment>.yaml` per deployment, with every value filled in. |

Not created, by design: the application releases (step 2), and the data
root's StorageClass (the chart creates it).

## Architecture

```
                         Internet
                            │  HTTPS
                            ▼
              ┌───────────────────────────┐
              │ Front Door                │  TLS terminates here, on a Microsoft-issued,
              │ one endpoint per          │  Microsoft-rotated certificate for each
              │ deployment                │  Azure-generated hostname
              └─────────────┬─────────────┘
                            │  HTTP, admitted only from AzureFrontDoor.Backend
                            ▼
              ┌───────────────────────────┐
              │ Public load balancer      │  One Gateway for the cluster (approuting-istio).
              │ + Gateway                 │  Each deployment adds an HTTPRoute, matched on
              └─────────────┬─────────────┘  the endpoint hostname
                            ▼
   ┌──────────────────────────────────────────────────────────────────┐
   │ AKS: ONE node, no autoscaler                                     │
   │                                                                  │
   │   namespace per deployment: api · web · worker · vfs · sandbox   │
   │                             + data-root Pod + sandbox runners    │
   │   Kata Containers (cluster-wide, installed by Terraform)         │
   └──────┬──────────────────────────┬─────────────────────────┬──────┘
          │                          │                         │
          ▼                          ▼                         ▼
   ┌──────────────┐          ┌───────────────┐        ┌──────────────────┐
   │ PostgreSQL   │          │ Blob store    │        │ Data-root disk   │
   │ Flexible     │          │ prefix per    │        │ per deployment:  │
   │ Server 18    │          │ deployment    │        │ Premium SSD,     │
   │ (private)    │          │ (firewalled)  │        │ raw block, btrfs │
   └──────────────┘          └───────────────┘        └──────────────────┘
```

## Infrastructure and deployments

`infra_id` names the shared infrastructure, provisioned once. `deployment_ids`
lists the application deployments hosted on it. Each name is a deployment's
**namespace and Helm release name**, and gets its own service account,
database and roles, blob key prefix, Key Vault key, Front Door endpoint, Entra
ID app registration, encryption keys, and values file.

The deployments share one managed identity, so the boundary between them in
the blob container is the key prefix, not a credential. They also share the
one node, so every deployment added divides the same sandbox capacity.

## Usage

Prerequisites:

- The Azure CLI, logged in (`az login`) to the subscription in your tfvars.
- Terraform ≥ 1.13, `kubectl`, and `helm`.
- Rights to create the resources above, including role assignments.
- Microsoft Graph rights to create app registrations
  (`Application.ReadWrite.OwnedBy`, or the Application Administrator / Cloud
  Application Administrator role), unless `create_entra_apps = false`.

Configure your state backend in `terraform.tf` first: without one, state is a
local file, and it holds every generated secret.

### 1. Apply

A new cluster applies in three passes:

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform apply -target=module.aks   # the cluster, with the Gateway API turned on
terraform apply                      # everything else
terraform apply                      # a minute later: Front Door's origin
```

1. Terraform can plan the Gateway only once the cluster and its Gateway API
   definitions exist, so the cluster goes first.
2. The second pass installs Kata Containers, which restarts containerd on the
   node and can take up to 25 minutes. Then a Job per deployment creates its
   database and roles from inside the cluster, because the server has no
   public endpoint.
3. AKS allocates the Gateway's public IP a minute or so after the Gateway is
   created, and the last pass points Front Door at it: its plan creates the
   origin, the routes, and the network security group. If it plans none of
   them, the IP is not there yet: wait a minute and apply again. Until then
   every endpoint answers 404. Afterwards, Front Door takes 10–20 minutes to
   reach every edge, and answers 504 `OriginTimeout` in the meantime.

When a pass fails:

- **`job: sema4ai-database-setup/<deployment> is in failed state`**: read why
  with `kubectl -n sema4ai-database-setup logs job/<deployment>`, after
  `eval "$(terraform output -raw aks_get_credentials_command)"`.
- **`403 Forbidden` creating the Key Vault keys**: apply again. Azure takes a
  minute or two to honor the role Terraform just granted itself on the vault.

### 2. Install (per deployment)

Install the chart, version 3.1.4 or later; step 7 of the
[deployment guide](https://sema4.ai/docs/v3/deploy/azure-aks) has the chart
reference and the registry login. Terraform prints the command with the
release, namespace, kube context, and values file filled in:

```bash
eval "$(terraform output -raw aks_get_credentials_command)"
DEPLOYMENT=sema4ai
terraform output -json helm_install_commands | jq -r --arg d "$DEPLOYMENT" '.[$d]'
```

Install into that namespace and no other, without `--create-namespace`:
Terraform created it with the service account the values file names, and the
federated credential that gives the account Azure access names that exact
namespace and account.

The VFS and sandbox Pods sit in `ContainerCreating` for a few minutes on a
first install, until the data root is mounted.

### 3. Verify

```bash
kubectl -n $DEPLOYMENT get pods

# The data root: a Bound claim, and a log ending in "data root ready"
kubectl -n $DEPLOYMENT get pvc -l app.kubernetes.io/component=data-root
kubectl -n $DEPLOYMENT logs daemonset/$DEPLOYMENT-blockparty-data-root -c data-root-manager

# The workload identity in the VFS Pod. No output means the service account
# annotation or the federated credential is missing, and blob operations will
# fail with 403.
kubectl -n $DEPLOYMENT describe pod -l app.kubernetes.io/component=vfs | grep AZURE_

# The HTTPRoute, accepted with every backend resolved: both conditions True
kubectl -n $DEPLOYMENT get httproute $DEPLOYMENT-blockparty \
  -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}{"\n"}'

# The deployment through the edge
curl -fsS -o /dev/null -w '%{http_code}\n' \
  "$(terraform output -json front_door_endpoints | jq -r --arg d "$DEPLOYMENT" '.[$d]')"
```

Then open the URL in a browser: sign-in redirects to your identity provider,
and the **first user to sign in becomes the deployment's owner**, so sign in
yourself before opening access more widely.

Finally, run an agent that uses the sandbox. The sandbox runtime and the
application both install and report healthy on a node without `/dev/kvm`, so
only an agent run proves the node, along with the data root, the database,
and the blob store. Expect the first run to be slow while the caches fill.

To look inside the blob container, let your address through the storage
firewall for the length of the check. Listing also needs a data role on the
container for your own account, such as Storage Blob Data Reader.

```bash
ACCOUNT="$(terraform output -json blob_store | jq -r .storage_account_name)"
RG="$(terraform output -raw resource_group_name)"
MYIP="$(curl -s https://api.ipify.org)"

az storage account network-rule add --account-name "$ACCOUNT" --resource-group "$RG" --ip-address "$MYIP"
az storage blob list --account-name "$ACCOUNT" --container-name sema4ai-blobs \
  --prefix "$DEPLOYMENT/" --auth-mode login --output table
az storage account network-rule remove --account-name "$ACCOUNT" --resource-group "$RG" --ip-address "$MYIP"
```

### 4. Back up the encryption keys

Each rendered values file holds two keyrings, `api.config.secretsKeys` and
`api.config.projectPortabilityKeys`, which encrypt the credentials the
platform stores in its database and its exported project archives. The
database outlives the cluster, and **anything encrypted with a lost key cannot
be read back**. Store both in your secrets manager, so they survive the loss
of the values file and of the Terraform state.

Removing a deployment from `deployment_ids` destroys its keys: re-adding the
same name generates new ones, and its old data becomes unreadable.

## Ingress

Behind Front Door is the **Kubernetes Gateway API**, served by the application
routing add-on's Gateway API implementation. Microsoft names it as the
successor to the add-on's NGINX, which it supports only
[through November 2026](https://learn.microsoft.com/en-us/azure/aks/app-routing-gateway-api),
and it is the ingress Sema4.ai recommends and tests on Azure. The cluster has
one Gateway (`gateway.tf`) behind one public load balancer. Each deployment's
release attaches an HTTPRoute to it for the deployment's own Front Door
hostname, which Front Door passes through as the Host header.

To use an ingress controller of your own, replace the `httpRoute` block in
`templates/values.yaml.tftpl` with an `ingress` block (`enabled: true`, plus
the class, host, TLS, and annotations the controller needs). For another
Gateway API implementation, point `httpRoute.parentRefs` at its Gateway.
Either way, change the lookup in `front-door.tf`, which finds the origin by
this Gateway's Service. The guide's
[Using your own ingress](https://sema4.ai/docs/v3/deploy/advanced-configuration#using-your-own-ingress)
lists what any ingress must provide.

What the Front Door shape trades away:

- **The edge-to-cluster hop is plain HTTP**, because Front Door accepts only
  an HTTPS origin whose certificate chains to a public root. The network
  security group therefore admits port 80 only from the
  `AzureFrontDoor.Backend` service tag.
- **That tag covers every Front Door, not only yours.** Closing the gap means
  rejecting, on each route, requests whose `X-Azure-FDID` header is not this
  profile's ID (`resource_guid` on `azurerm_cdn_frontdoor_profile.this`).
- **Front Door's limits become the application's**: 240 seconds for a single
  non-WebSocket response, and Front Door's own WebSocket limits.
- **No upload size limit in the cluster**: this Gateway API implementation
  [cannot set one](https://learn.microsoft.com/en-us/azure/aks/app-routing-gateway-api#limitations).

For production, use the shape the deployment guide describes: a hostname on
your own domain, and an HTTPS listener on the Gateway with a certificate from
Key Vault (step 3 of the [guide](https://sema4.ai/docs/v3/deploy/azure-aks),
and Microsoft's
[Configure Azure DNS and TLS with the application routing Gateway API implementation](https://learn.microsoft.com/en-us/azure/aks/app-routing-gateway-api-dns-tls)).
Point `gateway_listener` in `gateway.tf` at that listener, set the routes'
hostnames to yours, and remove `front-door.tf`, including the network security
group, which admits only Front Door on port 80 and would block HTTPS clients.
To keep Front Door instead, the Premium SKU with Private Link to an internal
load balancer removes the public origin, and a custom domain on each endpoint
replaces the generated hostname.

## The data root

Each deployment keeps its node-local state on a raw block volume claimed from
a StorageClass the chart creates: Premium SSD on the Azure Disk CSI driver,
100 GiB by default. It is a cache, not the system of record: a replaced node
starts cold and re-materializes from the blob store.

Premium SSD performance scales with size (100 GiB is a P10 at 500 IOPS,
512 GiB a P20 at 2,300 IOPS), and an undersized data root shows up as slow
runs rather than as errors. Raise `vfs.dataRoot.size` in the values file and
upgrade: the volume grows without a restart, and can never shrink. For a
customer-managed disk key, or IOPS independent of size, name a StorageClass of
your own in `vfs.dataRoot.storageClassName`; see
[Advanced configuration](https://sema4.ai/docs/v3/deploy/advanced-configuration#a-custom-storageclass-for-the-data-root).

## Cleanup

```bash
helm uninstall "$DEPLOYMENT" -n "$DEPLOYMENT"   # each deployment first
terraform destroy                               # then everything else
```

Uninstalling a deployment removes its data-root disk, not its database or its
blobs. Removing it from `deployment_ids` and applying deletes its namespace,
federated credential, Front Door endpoint, Entra ID app registration, Key
Vault key, and database setup Job, and **destroys its encryption keys**
(step 4). Its database, roles, and blobs stay: drop or empty them yourself,
because re-adding the same name points a new deployment, with new keys, at the
old objects.

## Layout

```
.
├── terraform.tf              # providers; add your state backend here
├── variables.tf              # inputs, documented inline
├── main.tf                   # resource group, network, PostgreSQL, AKS
├── front-door.tf             # Front Door, an endpoint per deployment, origin NSG
├── gateway.tf                # the cluster's one Gateway, the Front Door origin
├── sandbox-runtime.tf        # Kata Containers, the sandbox runtime
├── deployments.tf            # blob store, identity, Key Vault; per deployment: namespace,
│                             #   service account, federated credential, Entra app, keys,
│                             #   rendered values
├── databases.tf              # per deployment: the Job that creates its database and roles
├── outputs.tf                # only what this README uses
├── terraform.tfvars.example
├── templates/
│   ├── values.yaml.tftpl     # Helm values template (one rendered file per deployment)
│   └── database.sql.tftpl    # a deployment's database and roles (idempotent)
├── rendered/                 # generated values-<deployment>.yaml (gitignored, 0600)
└── modules/
    ├── aks/                  # cluster, node pool, OIDC issuer, Gateway API (application routing)
    ├── networking/           # virtual network, node subnet, delegated database subnet
    ├── postgres/             # Flexible Server, private DNS zone, extension allow-list
    ├── blob-store/           # storage account + container, firewall
    ├── key-vault/            # vault, one key per deployment, role assignments
    ├── entra-app/            # Entra ID app registration (OIDC client)
    └── app-namespace/        # namespace + service account for one deployment
```
