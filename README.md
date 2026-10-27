# Azure Local Factory — Dell AX
PowerShell controller baseline for a site workflow from discovery through certification. Switch configuration is outside scope. Read IMPLEMENTATION-STATUS.md first: this package includes every proposed script entry point, but model-specific and version-specific actions require site adapters before end-to-end Apply is possible.

## Controller requirements
External Windows controller on the management network, PowerShell 7.4+, Azure CLI, powershell-yaml, trusted iDRAC/host certificates, authenticated Azure Government context, and secure access to iDRAC credentials. The controller must exist independently of the AX cluster. Configure management DHCP or known iDRAC addresses before remote discovery; power alone is insufficient.

```powershell
Install-Module powershell-yaml -Scope CurrentUser
az cloud set --name AzureUSGovernment
az login --tenant '<tenant-id>'
az account set --subscription '<subscription-id>'
# Set FACTORY_IDRAC_USER and FACTORY_IDRAC_PASSWORD from your secret store.
# Do not commit credentials or secure deployment parameter files.
```

1. Copy environments/site01.yaml and replace every REPLACE and example address. Match node service tags and provide iDRAC endpoints.
2. Implement missing adapters following docs/adapter-contract.md. Add adapter mappings. Review IMPLEMENTATION-STATUS.md and the stage operations: default hardware/OS stages validate existing state; automatic changes require explicit adapter wiring.
3. Download the Microsoft deployment template applicable to your Azure Local release and cloud. Put the template at azure/deployment/site-template.json and the secure parameters at secure/site-parameters.json. The parameters must include your actual networking, AD/DNS, storage and deployment identity requirements. Do not treat the abbreviated YAML as a complete Azure Local deployment parameter file.
4. Verify the subscription, resource group, provider registrations and identity permissions before running. Provider checks do not perform registration. Bicep main.bicep only creates a supporting resource group and is not the Azure Local template.
5. Run a plan; then complete adapters and test in a lab before Apply.

```powershell
.\controller\Invoke-AzureLocalFactory.ps1 -Environment .\environments\site01.yaml -Mode Plan
.\controller\Invoke-AzureLocalFactory.ps1 -Environment .\environments\site01.yaml -Mode Apply -ArtifactsPath D:\FactoryRuns -RunId site01-lab-001
.\controller\Resume-Onboarding.ps1 -Environment .\environments\site01.yaml -Mode Apply -ArtifactsPath D:\FactoryRuns -RunId site01-lab-001
```

Plan writes a plan only; it cannot certify readiness. Validate uses the same stages and rejects mutating operations, so the default onboarding workflow blocks at registration/deployment. To perform a read-only audit, create a separate environment workflow containing only validation operations; do not regard it as onboarding certification.

Runtime data lives outside source control. Use a durable restricted directory. Resume requires unchanged YAML and mode. Fix adapter code without changing configuration to resume; changed configuration requires a new run. Save the exact source revision alongside run evidence operationally. Controller prevents concurrent access to a single run; GitHub adds site workflow concurrency. Do not launch multiple independent runs for one site at the same time.

A failed gate stops and records a return stage. Remediation is operator-directed through Invoke-Remediation.ps1. Resume invalidates downstream passes and re-executes from the return stage. A stage return does not undo state or authorize destructive rollback. Stage 7 returns to itself to inspect deployment state rather than repeat registration or remove the cluster.

## References
- https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-introduction
- https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template
- https://learn.microsoft.com/en-us/azure/azure-local/manage/azure-arc-vm-management-overview
- https://github.com/dell/iDRAC-Redfish-Scripting

Arc Resource Bridge and Custom Location are created by Azure Local deployment. Configure-* entry points do not deploy duplicates and require site adapters where changes are actually needed.
