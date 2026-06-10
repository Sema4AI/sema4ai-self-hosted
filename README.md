# Sema4.ai Self-Hosted Deployment Resources

Supplementary resources for deploying the Sema4.ai platform in a self-hosted environment. This repository accompanies the official deployment documentation:

**📖 [Sema4.ai Deployment Documentation](https://sema4.ai/docs/v2/deploy)**

The documentation is the authoritative guide for planning and executing a self-hosted deployment. The materials here — reference infrastructure code, configuration examples, and helper scripts — are intended to make following that guide easier, not to replace it.

## Repository layout

Resources are organized by platform version, then by target environment:

```
v2.5/
  aws/      Reference materials for deploying on AWS (coming soon)
  azure/    Reference materials for deploying on Azure (coming soon)
```

Use the directory that matches the platform version you are deploying. Contents within a version directory may include Terraform modules, example configuration, and other deployment aids for the given cloud or environment.

## Suggested workflow: fork and track upstream

There are two common ways to manage your deployment IaC:

- **Maintain your own separate repository**, structured according to your organization's conventions, using this repository purely as a reference to copy from. In that case the workflow below does not apply.
- **Base your deployment IaC directly on this repository.** If you take this approach, fork this repository (or mirror it into your own git hosting) rather than cloning and editing in place. This keeps your customizations under version control while letting you pull in upstream updates as new platform versions and fixes are published.

For the fork-based approach:

1. Fork the repository and clone your fork.
2. Add this repository as an upstream remote:

   ```sh
   git remote add upstream https://github.com/Sema4AI/sema4ai-self-hosted.git
   ```

3. Commit your customizations (environment-specific variables, module adjustments) to your fork.
4. When updates are published, fetch and merge from upstream, resolving any conflicts between your customizations and the upstream changes:

   ```sh
   git fetch upstream
   git merge upstream/master
   ```

Keeping your changes as focused, well-described commits on top of upstream makes these merges easier to reason about.

## Usage notes

- Treat the contents as a starting point: review and adapt them to your organization's security, networking, and compliance requirements before use.
- Keep environment-specific values (credentials, `*.tfvars`, state files) out of version control — the included `.gitignore` already excludes common Terraform secrets and state.
- Always cross-check against the [deployment documentation](https://sema4.ai/docs/v2/deploy) for the version you are installing, as requirements may change between releases.

## Support

For questions about self-hosted deployments, contact your Sema4.ai representative or refer to the official documentation above.
