# GitHub Actions
Use a dedicated external Windows self-hosted runner with direct management reachability. Preinstall PowerShell 7.4, Azure CLI and powershell-yaml. Provision Azure authentication through your approved workload identity mechanism before execution; no secrets-based Azure login step is bundled. The controller validates the active cloud, tenant and subscription. Review and pin action versions according to repository policy. Runner D:/FactoryRuns must be persistent and restricted. Runtime evidence is intentionally not uploaded to GitHub artifacts by default.

onboard-site executes Apply; validate-site and certify-site default to Validate and will block against the full onboarding configuration where mutations are present. Provide a separate read-only audit workflow configuration for validate-site. certify-site is a reserved workflow entry point, not an independent shortcut to certification: certification is normally gate 11 of the successful onboarding run. Never make a validation-only environment certify a fresh site without all required prior gates.

## Current Execution Model

GitHub Actions is not part of the current operator workflow. The active execution path is the local deployment manager launched through `Run-AzureLocalDeploymentManager.cmd`. GitHub Actions workflow drafts are retained only as archived future-reference material.