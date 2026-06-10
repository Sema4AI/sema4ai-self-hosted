# Sema4.ai self-hosted — AWS prerequisites (reference infrastructure)

Terraform for the AWS resources Sema4.ai needs when self-hosted on AWS. This
is **reference infrastructure**: it shows a working, minimal way to provision
the prerequisites. Review it against your organization's standards (naming,
tagging, encryption, network, and compliance policies) and adapt it — or use
it simply as a specification of what the application requires.

> **Note:** Depending on your account and configuration, this infrastructure
> may not apply as-is — for example, the KMS key policy references the Auto
> Scaling service-linked role, which exists only once Auto Scaling has been
> used in the account. As reference infrastructure it also favors simplicity
> over strict isolation: when hosting multiple deployments,
> principle-of-least-privilege tweaks — such as deployment-specific database
> credentials and S3 access scoped to each deployment's key prefix, instead of
> the shared database credentials and bucket-wide policy used here — are
> strongly recommended for proper isolation.

It contains only the parts **generic to hosting on AWS**: the KMS key, the S3
bucket, the IAM policy granting the application access to them, and an
optional managed PostgreSQL. Anything specific to a compute platform — an EKS
cluster, VMs, Fargate, networking, ingress, and the application IAM role
(whose trust policy is inherently compute-specific) — is deliberately out of
scope and deployed as part of the compute configuration.

## Shared responsibility

**Sema4.ai provides**

- The application, deployed through the Sema4 Enterprise portal at
  https://get.sema4.ai.
- This reference Terraform for the application's AWS data-plane prerequisites
  (KMS, S3, IAM role, optional Aurora PostgreSQL).

**You (the customer) are responsible for**

- The AWS account and everything operational in it: state storage for this
  Terraform, backups, monitoring, cost, and security hardening.
- **The Kubernetes platform** — the cluster (EKS or otherwise), networking/VPC,
  node groups, and add-ons. If you use EKS Pod Identity, the
  `eks-pod-identity-agent` add-on must be installed.
- **The application identity** — created as part of your compute
  configuration: the IAM role with the trust policy your platform needs (EKS
  Pod Identity, ECS/Fargate task role, EC2 instance profile, IRSA) and this
  project's access policy attached, the namespace and service account the
  application runs as, and the binding between them (see step 3 below).
- **Ingress** — exposing the application (load balancer, ingress controller,
  TLS certificates, DNS). The application serves plain HTTP on port 8001 with
  a `/health/live` probe; terminate TLS in your ingress.
- An **OIDC identity provider** and a client registration for the application.
- **PostgreSQL 17**, unless you enable the optional Aurora module here — and
  even then, operating it (backups, upgrades, access control) is yours.

## What this creates

1. A **customer-managed symmetric KMS key** — the envelope-encryption KEK for
   application data, also used as the SSE-KMS key on every S3 object the
   application writes (and as the storage key for the optional Aurora
   cluster).
2. An **S3 bucket** for file payloads (versioned, public access blocked,
   SSE-KMS with the key above).
3. An **IAM policy** granting access to exactly that bucket and key. The
   application IAM *role* is deliberately not created here — a role cannot
   exist without a trust policy, and trust is compute-specific — so you create
   the role in your compute configuration and attach this policy (step 3
   below).
4. **Optional** (`create_database = true`): an **Aurora Serverless v2
   PostgreSQL 17** cluster in subnets you supply, encrypted with the KMS key.
   The application creates its own database on first start, so no manual
   bootstrap is needed.
5. A **rendered Helm values file per deployment**
   (`rendered/values-<deployment>.yaml`) with everything this project knows
   pre-filled; the remaining `REPLACE_ME` fields (service exposure,
   `externalUrl`, OIDC client, and the database connection if you bring your
   own) are yours to fill.

> **Critical: the KMS key.** It wraps every encrypted database column and S3
> object. **Losing it makes the data unrecoverable.** Key rotation is enabled
> and the deletion window is 30 days; restrict who can schedule its deletion.

## Infrastructure and deployments

The configuration has two constructs:

- **`infra_id`** names the shared infrastructure — the KMS key, the S3
  bucket, the IAM access policy, and the optional Aurora cluster. It is
  provisioned once.
- **`deployment_ids`** lists the application deployments hosted on that
  infrastructure. One infrastructure can power multiple deployments (e.g.
  production and staging). Each name yields a rendered values file with the
  deployment-derived fields filled in: the PostgreSQL database name, the S3
  key prefix, and the service account name.

What is shared and what is per-deployment:

- Each deployment gets its **own PostgreSQL database** (created by the
  application on first start). Note that the rendered values files all carry
  the same cluster-level credentials, so this separates data but does not
  enforce isolation on its own — create deployment-specific database users
  for that (see the note above).
- The **S3 bucket and KMS key are shared**. When the bucket is shared by
  multiple deployments, each application MUST be configured with its own
  `s3KeyPrefix` (the rendered values pre-fill it with the deployment name) —
  prefix separation is a convention, not an enforced boundary.
- Each deployment needs its **own Kubernetes namespace**: only one deployment
  can be installed in a single namespace. The identity chain of step 3
  (service account, role binding) is therefore created per deployment.

## Usage

Prerequisites: Terraform ≥ 1.9, AWS credentials, `kubectl` for the
install steps. Configure your state backend in `terraform.tf` first (with no
backend, state is local — and it contains the database password when the
optional Aurora cluster is enabled).

### 1. Apply

```hcl
# terraform.tfvars
region         = "eu-west-1"
infra_id       = "sema4"       # names the shared infra (KMS alias, S3 bucket, IAM policy)
deployment_ids = ["sema4ai"]   # one entry per deployment, e.g. ["prod", "staging"]

# Optional managed database (otherwise bring your own PostgreSQL 17):
# create_database     = true
# database_subnet_ids = ["subnet-...", "subnet-..."]   # >= 2 AZs, same VPC as your cluster
```

```bash
terraform init
terraform apply
```

### 2. Fill the values file (per deployment)

`rendered/values-<deployment>.yaml` has the AWS fields (region, bucket, KMS
key) and the deployment-derived fields (database, S3 key prefix, service
account) pre-filled — plus the PostgreSQL connection when
`create_database = true`.
Fill every remaining `REPLACE_ME` (service exposure/ingress, `externalUrl`,
the OIDC client, and the database connection if you brought your own). The
filled file contains credentials — but a secret set once at install is
preserved by later deploys that omit it, so after the initial setup you can
remove `postgres.password` and `oidcClientSecret` and keep the file in
version control if desired.

### 3. Create the application identity: IAM role, service account, binding

The whole identity chain is yours to create before setup, as part of your
compute configuration, **once per deployment**: an IAM role with the trust
policy matching your platform and this project's access policy
(`terraform output -raw app_policy_arn`) attached, the deployment's namespace
(one deployment per namespace) and service account (the values file ships
`serviceAccount.create: false` with the name pre-filled), and the binding
between the two:

| Platform | Trusted service principal | Binding |
|---|---|---|
| EKS Pod Identity | `pods.eks.amazonaws.com` (actions `sts:AssumeRole` + `sts:TagSession`) | Pod Identity association to the namespace/service-account |
| ECS / Fargate | `ecs-tasks.amazonaws.com` | `taskRoleArn` in the task definition |
| EC2 | `ec2.amazonaws.com` | Instance profile attached to the instances |
| IRSA | Your cluster's OIDC provider | `eks.amazonaws.com/role-arn` annotation on the service account |

Example for EKS Pod Identity:

```bash
# IAM role with Pod Identity trust + the access policy from this project
aws iam create-role --role-name <deployment>-app \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "pods.eks.amazonaws.com" },
      "Action": ["sts:AssumeRole", "sts:TagSession"]
    }]
  }'
aws iam attach-role-policy --role-name <deployment>-app \
  --policy-arn "$(terraform output -raw app_policy_arn)"

# Namespace + service account the application runs as
kubectl create namespace <namespace>
kubectl -n <namespace> create serviceaccount <deployment>-app

# Binding: Pod Identity association between the two
aws eks create-pod-identity-association \
  --cluster-name <your-cluster> \
  --namespace <namespace> \
  --service-account <deployment>-app \
  --role-arn "arn:aws:iam::<account-id>:role/<deployment>-app"
```

### 4. Install

Trigger the deployment from the Sema4 Enterprise portal at
https://get.sema4.ai; it asks for the values file during setup. Setup cannot
proceed until every `REPLACE_ME` in the file is filled.

Smoke test:

```bash
kubectl -n <namespace> port-forward svc/<service> 8001:8001
curl -fsS http://localhost:8001/health/live    # -> 200 {"status":"ok"}
```

## Layout

```
.
├── terraform.tf        # providers; add your state backend here
├── variables.tf · main.tf · values.tf · outputs.tf
├── templates/values.yaml.tftpl
├── rendered/           # generated values files (gitignored — contains credentials)
└── modules/
    ├── prereqs/              # KMS key + S3 bucket + application access policy
    └── rds-aurora-pg/        # optional Aurora Serverless v2 PostgreSQL 17
```
