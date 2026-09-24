# Sema4.ai self-hosted v3 — Azure AKS (reference infrastructure)

Terraform for running Sema4.ai v3 on **Azure Kubernetes Service**: the
cluster with its sandbox-capable node, and every Azure resource the
application depends on — PostgreSQL, blob storage, the Key Vault key, the
workload identity, the Entra ID app registrations used for sign-in, and the
Azure Front Door that fronts it all. It installs the sandbox runtime, creates
each deployment's database and roles, and renders a completed Helm values
file for each deployment, so the one step left to you is installing the
application chart.

This is **reference infrastructure**: a working, minimal way to provision
everything the application needs on Azure. Review it against your
organization's standards (naming, tagging, network, identity, and compliance
policies) and adapt it, or use it as a specification for your own tooling
(Bicep, ARM, or existing shared infrastructure).

The deployment guide is the authoritative description of the requirements
and the install:

**📖 [Deploy on Azure AKS](https://sema4.ai/docs/v3/deploy/azure-aks)**

> **One deliberate difference from the guide: the public hostname.** The
> guide has you pick a hostname on your own domain and terminate TLS in the
> cluster with a certificate from Key Vault. This configuration
> instead serves each deployment at an **Azure-generated Front Door
> hostname** (`<deployment>-<hash>.z01.azurefd.net`) with a certificate
> Microsoft issues and rotates, so a proof of concept needs no domain, DNS
> record, or certificate. Read [Ingress](#ingress) for what that trades
> away, and for how to move to your own hostname.

## Shared responsibility

**Sema4.ai provides**

- The application, as a Helm chart.
- This reference Terraform, and the
  [sandbox runtime reference configuration](../../kata-containers/kata-values.yaml).

**You (the customer) are responsible for**

- The Azure subscription and everything operational in it: state storage for
  this Terraform, backups, monitoring, cost, and security hardening.
- **Installing the application** into each deployment's namespace with the
  rendered values file (step 2 below).
- **Operating what Terraform installed**: upgrading the sandbox runtime with
  the guide, and running the PostgreSQL server.
- **The encryption keys** in each rendered values file: backing them up
  outside the cluster (step 4 below).
- An **identity provider**, unless you let this configuration create an Entra
  ID app registration per deployment.

## What this creates

| Resource | Role |
| --- | --- |
| **Resource groups** `rg-<infra_id>` and `rg-<infra_id>-aks-nodes` | The first holds everything below; AKS creates the second for the node VM, its disks, and the Gateway's load balancer. |
| **Virtual network** | A node subnet (with the `Microsoft.Storage` and `Microsoft.KeyVault` service endpoints) and a subnet delegated to PostgreSQL. |
| **AKS cluster** (Free tier) | Kubernetes 1.36+, OIDC issuer and workload identity enabled, Azure CNI Overlay, and ingress through the Kubernetes Gateway API: the managed Gateway API CRDs and the application routing add-on's Gateway API implementation (`approuting-istio`), with the add-on's retired NGINX off. |
| **Node pool** (1 × `Standard_D32s_v5`, one zone) | 32 vCPU / 128 GiB with nested virtualization. Carries the whole application *and* every concurrent sandbox run. No autoscaler. |
| **PostgreSQL Flexible Server 18** | Application data, shared by every deployment (a database and three roles each). Private access only. `pgcrypto` and `citext` allow-listed. The application supports PostgreSQL 17 or 18. |
| **Storage account + container** | The durable blob store, shared by every deployment under its own key prefix. Zone-redundant (ZRS). Firewalled to the node subnet. |
| **Key Vault** | One RSA key per deployment: the chart's `infrastructure.azure.keyVaultKeyUrl`, reserved for envelope encryption of secrets at rest and for encrypting small values directly under it. It permits encrypt, decrypt, wrap key, and unwrap key. The chart requires it now, so the install contract is final before those features ship. |
| **User-assigned managed identity** | Storage Blob Data Contributor on the container and Key Vault Crypto User on each deployment's key, and nothing else. Federated with each deployment's service account. |
| **Entra ID app registrations** (optional) | The OIDC client for sign-in, one per deployment. |
| **Front Door** (Standard) | One endpoint per deployment: the public edge and the only place TLS is terminated. |
| **Network security group** | Admits only Front Door to the Gateway's load balancer. |
| **Gateway** (in the cluster) | One for the cluster, shared by every deployment: a single HTTP listener, the Front Door origin. Each deployment's release attaches an HTTPRoute to it. |
| **Sandbox runtime** (in the cluster) | Kata Containers from the Kata project's chart, with the [reference configuration](../../kata-containers/kata-values.yaml), once for the cluster. |
| **Per deployment, in the cluster** | A namespace, a service account annotated with the managed identity's client ID, and a Job that creates the deployment's database and its three roles on the PostgreSQL server. |
| **Per deployment, on disk** | `rendered/values-<deployment>.yaml`: every value filled in, and the install command in its header. |

Not created, by design: a StorageClass for the data root (the chart creates
it), and the application releases (step 2).

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
   │ AKS: ONE node, one zone, no autoscaler                           │
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
   │ Server 17    │          │ deployment    │        │ Premium SSD,     │
   │ (private)    │          │ (firewalled)  │        │ raw block, btrfs │
   └──────────────┘          └───────────────┘        └──────────────────┘
```

## Infrastructure and deployments

- **`infra_id`** names the shared infrastructure: the cluster and its node,
  the PostgreSQL server, the blob store and the identity that reaches it, the
  Key Vault, and the Front Door profile. It is provisioned once.
- **`deployment_ids`** lists the application deployments hosted on it. Each
  name is the deployment's **namespace and Helm release name**, and gets its
  own service account (`<name>-app`), federated identity credential,
  database and roles, blob key prefix, Key Vault key, Front Door endpoint,
  Entra ID app registration, generated encryption keys, and rendered values
  file.

Isolation between deployments is at the database (its own database and
roles), the node filesystem (its own data-root volume), the blob store (its
own key prefix), the Key Vault (its own key), and the namespace. They share
one managed identity, so the boundary in the blob container is the prefix, not
a credential.

All deployments share the one node, so every deployment added divides the
same sandbox capacity.

## Usage

Prerequisites:

- The Azure CLI, logged in (`az login`) to the subscription in your tfvars.
- Terraform ≥ 1.13, `kubectl`, and `helm`.
- Rights to create the resources above, including role assignments.
- Microsoft Graph rights to create app registrations
  (`Application.ReadWrite.OwnedBy`, or the Application Administrator / Cloud
  Application Administrator role), unless `create_entra_apps = false`.

Configure your state backend in `terraform.tf` first: with no backend, state
is local, and it holds every generated secret.

### 1. Apply

A new cluster applies in three passes:

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform apply -target=module.aks   # the cluster, with the Gateway API turned on
terraform apply                      # everything else: see below
terraform apply                      # a minute later: Front Door's origin
```

The Gateway is a Kubernetes object that Terraform can plan only once the
cluster and its Gateway API definitions exist, so the cluster goes first.

The second pass does the rest of the cluster's setup, in order, and waits for
each part:

1. Kata Containers is installed from the Kata project's chart, with the
   [reference configuration](../../kata-containers/kata-values.yaml). This
   restarts containerd on the node, and can take up to 25 minutes.
2. A Job per deployment creates its database and three roles on the
   PostgreSQL server, from inside the cluster, because the server has no
   public endpoint.

Front Door's origin is the Gateway's public IP, which AKS allocates a minute
or so after the Gateway is created, so the last pass picks it up:
`terraform output front_door_origin` is no longer `null`. If it still is,
wait a minute and apply again. Until the origin exists, every endpoint answers
404. Once it does, Front Door takes 10–20 minutes to push it to every edge,
and the endpoint answers 504 `OriginTimeout` until then: propagation, not a
fault.

When a pass fails:

- **`job: sema4ai-database-setup/<deployment> is in failed state`**: read
  why with `kubectl -n sema4ai-database-setup logs job/<deployment>`, after
  `eval "$(terraform output -raw aks_get_credentials_command)"`.
- **`403 Forbidden` creating the Key Vault keys**: apply again. Terraform
  grants itself the key-management role on the vault it just created, and
  Azure takes a minute or two to honor it.
- **A warning that the cluster runs a Kubernetes version older than 1.36**:
  the application is not supported on it. Check what the region offers with
  `az aks get-versions --location <location> --output table`, set
  `kubernetes_version`, and apply again.

### 2. Install (per deployment)

Install the chart, version 3.1.4 or later, into the deployment's namespace,
with the deployment name as the release name, using the rendered values file.
For the chart reference and the registry login, follow step 7 of the
[deployment guide](https://sema4.ai/docs/v3/deploy/azure-aks).
Terraform prints the command with the release, namespace, kube context and
values file already filled in:

```bash
eval "$(terraform output -raw aks_get_credentials_command)"
DEPLOYMENT=sema4ai
terraform output -json helm_install_commands | jq -r --arg d "$DEPLOYMENT" '.[$d]'
```

Do not pass `--create-namespace` or install elsewhere: Terraform created the
namespace with the service account the values file names, and the federated
credential that gives it Azure access names that exact namespace and account.

Expect the VFS and sandbox Pods to sit in `ContainerCreating` for a few
minutes on a first install, until the `data-root` Pod has claimed, formatted
and mounted the data root.

### 3. Verify

Check the node first. The sandbox runtime installs onto a node without
`/dev/kvm` and reports success, and so does the application; only agent runs
fail.

```bash
kubectl apply -f k8s/kvm-check.yaml
kubectl -n default wait --for=condition=complete job/kvm-check --timeout=120s
kubectl -n default logs job/kvm-check
kubectl -n default delete job kvm-check
```

A healthy node prints a `/dev/kvm` character device and `vmx` among the CPU
flags. A `MISSING` line means the VM size does not provide nested
virtualization: change `node_vm_size` and apply again (the node is replaced).

Then the deployment:

```bash
# The sandbox runtime Terraform installed: both return an object
kubectl get runtimeclass kata-clh
kubectl get nodes -l katacontainers.io/kata-runtime=true

kubectl -n $DEPLOYMENT get pods

# The data root: a Bound claim, and a log ending in "data root ready"
kubectl -n $DEPLOYMENT get pvc -l app.kubernetes.io/component=data-root
kubectl -n $DEPLOYMENT logs daemonset/$DEPLOYMENT-blockparty-data-root -c data-root-manager

# The workload identity the AKS webhook injected into the VFS Pod. No output
# means the annotation or the federated credential is missing, and blob
# operations will fail with 403 on first use.
kubectl -n $DEPLOYMENT describe pod -l app.kubernetes.io/component=vfs | grep AZURE_

# The deployment's HTTPRoute, accepted by the Gateway with every backend
# resolved: both conditions True
kubectl -n $DEPLOYMENT get httproute $DEPLOYMENT-blockparty \
  -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}{"\n"}'

# The deployment through the edge
curl -fsS -o /dev/null -w '%{http_code}\n' \
  "$(terraform output -json front_door_endpoints | jq -r --arg d "$DEPLOYMENT" '.[$d]')"
```

Then open the URL in a browser: sign-in should redirect to your identity
provider, and the **first user to sign in becomes the deployment's owner**, so
sign in yourself before opening access more widely. Finally, run an agent that
exercises the sandbox, which proves the data root, the sandbox runtime, the
database and the blob store together. Expect the first run to be slow while
the caches fill.

To look inside the blob container, allow your own address through the
storage firewall for the length of the check:

```bash
ACCOUNT="$(terraform output -json blob_store | jq -r .storage_account_name)"
RG="$(terraform output -raw resource_group_name)"
MYIP="$(curl -s https://api.ipify.org)"

az storage account network-rule add --account-name "$ACCOUNT" --resource-group "$RG" --ip-address "$MYIP"
az storage blob list --account-name "$ACCOUNT" --container-name sema4ai-blobs \
  --prefix "$DEPLOYMENT/" --auth-mode login --output table
az storage account network-rule remove --account-name "$ACCOUNT" --resource-group "$RG" --ip-address "$MYIP"
```

Listing needs a data role on the container for your own account (for example
Storage Blob Data Reader).

### 4. Back up the encryption keys

Each rendered values file holds two keyrings, `api.config.secretsKeys` and
`api.config.projectPortabilityKeys`, that encrypt the credentials the platform
stores in its database. The database outlives the cluster, and **anything
encrypted with a lost key cannot be read back**. Store both values in your
secrets manager, so they survive the loss of the workstation holding the
values file and of the Terraform state.

The corollary: removing a deployment from `deployment_ids` destroys its
generated keys, so re-adding the same name generates new ones and its old data
becomes unreadable.

## Ingress

Every deployment is reached at its own Front Door endpoint, and Front Door
terminates TLS there on a certificate Microsoft issues, serves and rotates.
There is no domain to own, no DNS record to create, and no certificate in the
cluster. The hostnames exist only after an apply, so the values files'
`applicationUrl` and HTTPRoute hostname, and the Entra ID redirect URIs, are
read back off the endpoints; `terraform output front_door_endpoints` lists
them.

Behind the edge is the **Kubernetes Gateway API**. The application routing
add-on's managed NGINX is retired: Microsoft supports it only
[through November 2026](https://learn.microsoft.com/en-us/azure/aks/app-routing-gateway-api)
and names the add-on's Gateway API implementation as its successor. The
cluster runs that implementation instead, with one Gateway (`gateway.tf`)
behind one public load balancer for the whole cluster. Each deployment's
release renders an HTTPRoute onto it, with the same paths and Services as the
application's Ingress. All endpoints share a single Front Door origin that
forwards the Host header unchanged, so the Gateway matches each request to the
deployment whose HTTPRoute claims that hostname.

This Gateway API implementation is the ingress Sema4.ai recommends on Azure,
and the only one we test there: the upstream
[ingress-nginx](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
project the add-on's NGINX is built on is end of life. The application itself
works with any ingress. On Azure the chart renders no Ingress unless asked to,
so to use an ingress controller of your own, replace the `httpRoute` block in
`templates/values.yaml.tftpl` with an `ingress` block that sets
`enabled: true`, the class, and the host, TLS and annotations the controller
needs; to use another Gateway API implementation, point `httpRoute.parentRefs`
at its Gateway. Either way, `front-door.tf` finds the origin by this Gateway's
Service, so change that lookup to match. The guide's
[Using your own ingress](https://sema4.ai/docs/v3/deploy/advanced-configuration#using-your-own-ingress)
lists what any ingress must provide.

What this shape trades away:

- **The edge-to-cluster hop is plain HTTP.** Front Door only accepts an HTTPS
  origin whose certificate chains to a public root, and the Gateway has none.
  The network security group therefore admits port 80 only from the
  `AzureFrontDoor.Backend` service tag.
- **The service tag covers every Front Door, not only yours.** Anyone who
  learns the origin IP can reach it through a Front Door profile of their own.
  Closing that means rejecting requests whose `X-Azure-FDID` header is not
  this profile's ID (`terraform output front_door_id`), with a header match on
  each deployment's route.
- **Front Door's limits become the application's.** A single non-WebSocket
  response is capped at 240 seconds at the edge, and WebSocket connections are
  subject to Front Door's own idle and duration limits. The Gateway adds no
  timeout of its own.
- **No upload size limit in the cluster.** This Gateway API implementation
  [cannot set a request body size limit](https://learn.microsoft.com/en-us/azure/aks/app-routing-gateway-api#limitations),
  so a request body reaches the application at whatever size it arrives.

For production, replace it with the shape the deployment guide describes: a
hostname on your own domain, and TLS in the cluster with a certificate from
Key Vault. On the Gateway API that is an HTTPS listener on the Gateway whose
TLS options name the certificate
(`kubernetes.azure.com/tls-cert-keyvault-uri`) and a service account bound to
an identity with Key Vault Secrets User on the vault
(`kubernetes.azure.com/tls-cert-service-account`), with the Key Vault
secrets provider add-on enabled; step 3 of the
[deployment guide](https://sema4.ai/docs/v3/deploy/azure-aks) has the
commands and the Gateway, and Microsoft's
[Configure Azure DNS and TLS with the application routing Gateway API implementation](https://learn.microsoft.com/en-us/azure/aks/app-routing-gateway-api-dns-tls)
the details. Each HTTPRoute attaches to the listener named by
`gateway_listener` in `gateway.tf`, so point that at the HTTPS listener and
set the routes' hostnames to yours. That also lets you keep the Gateway
private with an internal load balancer.
Remove the Front Door resources in `front-door.tf` when you do, including the
network security group: it admits only Front Door, on port 80, so it would
block HTTPS clients reaching a public Gateway directly. To keep Front Door
instead, the Premium SKU with Private Link to an internal load balancer
removes the public origin, and a custom domain on the endpoint replaces the
generated hostname (set it as `applicationUrl`, the HTTPRoute hostname and the
redirect URI).

## The data root

The application keeps its node-local state in one btrfs filesystem per
deployment, on a raw block volume its `data-root` Pod claims from a
StorageClass the chart creates: Premium SSD (`Premium_LRS`) on the Azure Disk
CSI driver, encrypted at rest with platform-managed keys. It is a cache, not
the system of record: a replaced node starts cold and re-materializes from the
blob store.

- **Premium SSD performance scales with size.** The 100 GiB default is a P10
  disk at 500 IOPS; 512 GiB is a P20 at 2,300 IOPS. Materialization is
  metadata-heavy, so an undersized data root shows up as slow runs rather than
  as an error. Raise `vfs.dataRoot.size` in the values file and upgrade: the
  volume and the filesystem grow without a restart. Shrinking is impossible.
- **A customer-managed disk key, or IOPS independent of size**, means a
  StorageClass of your own (on a disk encryption set, or on Premium SSD v2),
  named in `vfs.dataRoot.storageClassName`; see
  [Advanced configuration](https://sema4.ai/docs/v3/deploy/advanced-configuration#a-custom-storageclass-for-the-data-root).

## Cleanup

```bash
# One deployment. Its data-root disk goes with its Pods; its database and
# its blobs under the shared container stay.
helm uninstall "$DEPLOYMENT" -n "$DEPLOYMENT"

# Everything else (sandbox runtime, cluster, database, storage, Key Vault,
# Front Door, Entra apps). Uninstall every deployment first.
terraform destroy
```

Removing a deployment from `deployment_ids` and applying deletes its
namespace, federated credential, Front Door endpoint, Entra ID app
registration, Key Vault key and database setup Job, and **destroys its
generated encryption keys** (step 4). Its database, roles and blobs are not touched: drop or empty them
yourself if you mean to, because re-adding the same name points a new
deployment, with new keys, at the old objects.

## Layout

```
.
├── terraform.tf              # providers; add your state backend here
├── variables.tf              # inputs, documented inline
├── main.tf                   # resource group, network, PostgreSQL, AKS, version check
├── front-door.tf             # Front Door profile, an endpoint per deployment, origin NSG
├── gateway.tf                # the cluster's one Gateway, the Front Door origin
├── sandbox-runtime.tf        # Kata Containers, the sandbox runtime
├── deployments.tf            # blob store, identity, Key Vault; per deployment: namespace,
│                             #   service account, federated credential, Entra app, keys,
│                             #   rendered values
├── databases.tf              # per deployment: the Job that creates its database and roles
├── outputs.tf                # only what this README uses
├── terraform.tfvars.example
├── tests/
│   └── plan.tftest.hcl       # offline plan checks (mock providers): terraform test
├── templates/
│   ├── values.yaml.tftpl     # Helm values template (one rendered file per deployment)
│   └── database.sql.tftpl    # a deployment's database and roles (idempotent)
├── rendered/                 # generated values-<deployment>.yaml (gitignored, 0600)
├── k8s/
│   └── kvm-check.yaml        # node check: /dev/kvm, vmx, containerd socket
└── modules/
    ├── aks/                  # cluster, node pool, OIDC issuer, Gateway API (application routing)
    ├── networking/           # virtual network, node subnet, delegated database subnet
    ├── postgres/             # Flexible Server, private DNS zone, server parameters
    ├── blob-store/           # storage account + container, firewall
    ├── key-vault/            # vault, one key per deployment, role assignments
    ├── entra-app/            # Entra ID app registration (OIDC client)
    └── app-namespace/        # namespace + service account for one deployment
```
