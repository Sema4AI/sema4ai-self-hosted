# Sema4.ai self-hosted — Azure VM, one-click (Bicep / ARM)

A **portal-deployable** version of the [Azure VM prerequisites](../azure/) for
people who don't want to run Terraform. Click **Deploy to Azure**, fill in a
form, and the Azure Portal provisions everything into a resource group you pick.

This is the same infrastructure as [`v2.5/azure/`](../azure/) (the Terraform
reference), expressed in **Bicep** and compiled to an ARM template. Two
differences make it portal-friendly:

- **OIDC is not created here** — no Microsoft Graph rights needed. Bring your
  own identity provider (Entra ID, Okta, Auth0) and enter its details in the
  KOTS console.
- **The PostgreSQL password is generated** during deployment and returned as a
  deployment **output** for you to copy into the console.

> **Provisioning is not the whole install.** This template stands up the Azure
> resources. You still point DNS at the VM, run the application installer on it,
> and complete configuration in the admin console — see
> [After deployment](#after-deployment). Those steps come from the product's
> install model, not from this template.

## Deploy

> The buttons load the template from this repository's **default branch**, so
> they work once these files are present there. Until then, use
> [deploy from your machine](#deploy-from-your-machine).

**Guided form (recommended):**

[![Deploy To Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FSema4AI%2Fsema4ai-self-hosted%2Fmaster%2Fv2.5%2Fazure-bicep%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2FSema4AI%2Fsema4ai-self-hosted%2Fmaster%2Fv2.5%2Fazure-bicep%2FcreateUiDefinition.json)

**Plain parameter form:**

[![Deploy To Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FSema4AI%2Fsema4ai-self-hosted%2Fmaster%2Fv2.5%2Fazure-bicep%2Fazuredeploy.json)

## Before you click

- **You need an SSH public key.** The form asks for one. Generate it first:
  ```bash
  ssh-keygen -t ed25519 -f ~/.ssh/sema4ai
  cat ~/.ssh/sema4ai.pub   # paste this into the form
  ```
- **You need elevated rights on the subscription.** The template creates a
  **role assignment** (Storage Blob Data Contributor for the VM's identity), so
  the deploying user must be **Owner** or **User Access Administrator** — plain
  Contributor cannot create role assignments. (It also needs rights to create
  the resources, e.g. Contributor.)
- **Pick a resource group** in the form — choose **Create new** for a clean,
  easy-to-remove deployment.

## What it creates

Into the resource group you choose:

1. A **VNet** with a subnet delegated to PostgreSQL and a subnet for the VM.
2. A **PostgreSQL Flexible Server 17** (private access only, `uuid-ossp`
   allow-listed, the deployment database created).
3. A **Storage Account** + one blob container, network-restricted to the VM's
   subnet.
4. A **Key Vault** with a **customer-managed RSA KEK** (`wrapKey`/`unwrapKey`)
   for envelope encryption. Key Vault holds **only the KEK**.
5. A **user-assigned managed identity** on the VM, granted **Get / WrapKey /
   UnwrapKey** on the KEK and **Storage Blob Data Contributor** on the storage
   account.
6. The **VM** (Ubuntu 24.04, static public IP, NSG open to 443 + 22, data disk).

> **Critical: the KEK.** It wraps every encrypted secret at rest. **Losing it
> makes that data unrecoverable.** Restrict who can delete the Key Vault.

## After deployment

Open the deployment's **Outputs** tab (or
`az deployment group show -g <rg> -n <deployment> --query properties.outputs`).
It contains every value you need below, including the generated
`postgresPassword` — treat it as a secret.

1. **Point DNS at the VM.** Create an A record for your hostname (or use the
   `vmPublicFqdn` output) pointing at `vmPublicIp`. TLS is issued by the in-pod
   sidecar (Let's Encrypt, ACME TLS-ALPN-01) once the name resolves.
2. **Register your OIDC app** with your IdP — redirect URI
   `https://<hostname>/oidc/login/callback`, logout
   `https://<hostname>/oidc/logout/callback`, scopes `openid profile email`.
   Capture the discovery URL, client ID, and client secret.
3. **Install the application.** SSH in with the `sshCommand` output, get the
   install command from the [Sema4 Enterprise portal](https://get.sema4.ai), and
   run it with `sudo`. Set the admin-console password when prompted.
4. **Configure in the KOTS console.** Open it over the tunnel
   (`kotsAdminConsoleSshCommand` output) at `https://localhost:8800`, and on the
   **Config** screen enter the values from the deployment outputs — External
   URL, infrastructure platform (Microsoft Azure), storage account / container /
   key prefix, Key Vault key URL, Postgres host/port/user/password/database, and
   your OIDC details — then **Deploy**.
5. **Validate.** Browse to `https://<hostname>`; sign-in should redirect to your
   IdP. Run a smoke-test agent to confirm Postgres + Blob.

## Deploy from your machine

If you'd rather not use the button (or the files aren't on the default branch
yet):

```bash
az login
az group create -n sema4ai-<infraId> -l <region>
az deployment group create \
  -g sema4ai-<infraId> \
  -f azuredeploy.json \
  -p infraId=<infraId> adminSshPublicKey="$(cat ~/.ssh/sema4ai.pub)"
```

## Editing and rebuilding

`main.bicep` and `modules/*.bicep` are the source of truth; `azuredeploy.json`
is the compiled artifact the button loads. After changing any `.bicep`, rebuild:

```bash
az bicep build --file main.bicep --outfile azuredeploy.json
```

Commit the regenerated `azuredeploy.json` alongside the Bicep.

## Layout

```
.
├── main.bicep                # parameters, identity, module wiring, outputs
├── modules/
│   ├── networking.bicep      # VNet + VM subnet + delegated PostgreSQL subnet
│   ├── postgres.bicep        # PostgreSQL Flexible Server 17 (private, uuid-ossp)
│   ├── storage.bicep         # storage account + container + blob role assignment
│   ├── keyvault.bicep        # Key Vault + RSA KEK
│   └── vm.bicep              # Ubuntu 24.04 VM, NSG, data disk, cloud-init
├── cloud-init.yaml           # inlined into the VM at compile time
├── createUiDefinition.json   # the portal form (guided button)
└── azuredeploy.json          # compiled ARM template (what the buttons load)
```
