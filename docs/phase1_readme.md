# Phase 1 — HCN Foundation and Azure Arc Registration

## Purpose

Phase 1 prepares Azure Local host compute nodes (HCNs) for Azure Arc onboarding and Azure portal visibility.

Phase 1 begins after Azure Local OS installation and ends after each approved vanilla node is visible in the Azure portal as an Azure Arc-enabled server.

```text
Azure Local OS Installed
→ HCN desired-state configuration
→ Azure/bootstrap readiness
→ Azure Arc registration
→ Azure portal visibility
```

## Phase 1 End State

At Phase 1 completion, each approved vanilla Azure Local node is:

```text
Configured to the approved desired state
Unclustered
Not Azure Local cluster registered
Azure Arc-enabled
Visible in the Azure portal
Validated for node health and Arc health
```

Phase 1 does not:

```text
Create an Azure Local cluster
Join nodes to Active Directory
Deploy Azure Local through Azure portal, ARM, or Bicep
Create Storage Spaces Direct
Create Azure Resource Bridge
Create a custom location
Execute Phase 2, Phase 3, or Phase 4
```

---

# Workflow Diagram

![Azure Local Phase 1 Onboarding Workflow](/docs/images/Azure-Local-Onboarding-Workflow-Phase1.png)

## Text Workflow Summary

```text
Azure Local OS Installed
Local Administrator Set
Management VLAN/IP via SConfig
WinRM HTTPS Reachable
        │
        ▼
1.1 Input and Build Validation
        │
        ├── Action 4: 1.2A Discovery and Readiness
        │
        ├── Action 4: 1.2C Compliance Validation
        │
        ▼
1.2B Ensure HCN Desired State
        │
        ├── Already Compliant → Skip Change
        ├── Drift → Request Approval → Apply Desired State
        ├── Reboot Required → Pause → Approve → Reconnect → Revalidate
        └── Existing Cluster / Registration → Block and Preserve Evidence
        │
        ▼
1.3 Azure Local Node Bootstrap Readiness
        │
        ▼
1.4 Azure Arc Registration and Validation
        │
        ▼
Phase 1 End State
Nodes visible in Azure portal as Azure Arc-enabled servers
No cluster deployment
No Phase 2 execution
```

---

# Scope Boundary

## Current Scope

```text
1.1  Input and Build Validation
1.2A HCN Discovery and Readiness Validation
1.2B Ensure HCN Desired State
1.2C HCN Compliance Validation
1.3  Azure Local Node Bootstrap Readiness
1.4  Azure Arc Registration and Validation
```

## Deferred Scope

```text
Phase 2 Azure Local cluster deployment
Phase 3 post-deployment Azure Local services
Phase 4 operational validation and certification
```

Deferred phases remain:

```yaml
implemented: false
```

---

# Vanilla Host Handoff Contract

The factory assumes Azure Local installation has already completed.

Before factory handoff, a vanilla host must have:

```text
Azure Local OS installed
Local Administrator password configured
Management NIC connected to approved management VLAN
Management IP, prefix, and gateway assigned through SConfig
WinRM HTTPS reachable from approved execution host
No domain join
No cluster
No Azure Local registration
No Azure Arc registration
```

The factory is responsible for validating and applying the remaining approved desired state.

---

# Phase 1 Stages

## 1.1 — Input and Build Validation

1.1 validates configuration intent and package integrity.

```text
Site variables
Naming
Management IP allocation
Storage network allocation
DNS and AD configuration inputs
Execution host authorization
Required runtime references
Protected release manifest/package integrity
```

1.1 does not configure or inspect target-node state.

---

## 1.2A — HCN Discovery and Readiness Validation

1.2A is an independent read-only validation profile available through Deployment Manager Action 4.

It validates:

```text
Azure Local deployment state
Clustered/registered/reference state
WinRM transport
WinRM certificate mode
Node identity
Azure Local OS and policy
Hardware inventory
NIC inventory
Mellanox driver baseline
TPM
Secure Boot
Required Windows features
Official Azure Local connectivity validation
Official Azure Local hardware validation
```

1.2A creates separate artifacts:

```text
artifacts\<SITE>\validation\<run-id>\
```

It does not:

```text
Run Ensure-* operations
Request approval
Reboot a node
Register Arc
Advance onboarding state
```

---

## 1.2B — Ensure HCN Desired State

1.2B is the onboarding Apply stage.

It begins with the existing-cluster/registration mutation safety gate:

```text
Test-AzureLocalDeploymentState
```

A target that is already clustered or Azure registered must be blocked before any `Ensure-*` operation executes.

1.2B may validate and enforce:

```text
NIC role mapping
Embedded adapter inactive state
DHCP state
Management VLAN
Management IP, prefix, and gateway
DNS
NTP
Storage network IP/VLAN state
IPv6 registry and binding state
Local deployment administrator state
PowerShell remoting
Hostname
```

Expected behavior:

```text
Inspect current state
→ compare against resolved site variables
→ skip if compliant
→ request approval for disruptive drift
→ apply approved desired state
→ reboot/reconnect if required
→ post-change validation
```

Only run 1.2B against an approved vanilla onboarding target.

---

## 1.2C — HCN Compliance Validation

1.2C is an independent read-only compliance profile available through Deployment Manager Action 4.

It validates final desired state:

```text
Local deployment administrator lifecycle
Adapter design
DHCP
Management VLAN
Mellanox driver baseline
Management IP/gateway
DNS
NTP
Storage network readiness
RDMA
SR-IOV
IPv6
Active Directory readiness
TPM
Secure Boot
Required Windows features
```

Possible classifications include:

```text
Compliant
ReferenceDifference
ExpectedLifecycleState
NotApplicable
ConfigurationDeferred
ValidationFinding
```

Example:

```text
fseadm may be absent after bootstrap if the protected lifecycle policy permits removal.
```

---

## 1.3 — Azure Local Node Bootstrap Readiness

1.3 is validation-only in the current effort.

It validates:

```text
Azure Government authentication
Subscription
Permissions
Resource providers
Resource group
Azure endpoint connectivity
Node remains unclustered
Node remains unregistered
Bootstrap readiness contract
```

It does not:

```text
Create a cluster
Join a domain
Deploy Azure Local
Register Arc
```

---

## 1.4 — Azure Arc Registration and Validation

1.4 is the final executable Phase 1 capability.

Intended workflow:

```text
Validate Azure Arc inputs
→ validate Connected Machine agent readiness
→ approve Arc registration initiation
→ start interactive device-code registration
→ operator completes device-code sign-in
→ resume workflow
→ validate Azure Arc resource visibility
→ validate HIMDS, node health, and Arc health
```

Protected defaults remain safe:

```yaml
mode: ReadinessOnly
allow_registration: false
allow_device_code_registration: false
```

A future approved vanilla-host profile may enable:

```yaml
mode: InteractiveDeviceCode
allow_registration: true
allow_device_code_registration: true
```

Do not enable this profile for NRFT.

---

# Deployment Manager Usage

## Onboarding Actions

```text
1 - Run Next Onboarding Validation Stage
2 - Plan Phase 1 Onboarding Workflow
3 - Apply Next Onboarding Stage
```

## Independent Read-Only Validation

```text
4 - Run Read-Only Validation
```

Read-only validation profiles:

```text
1.2A HCN Discovery and Readiness Validation
1.2C HCN Compliance Validation
```

Read-only validation does not alter onboarding state.

## Evidence and Review

```text
5 - View Status and Evidence
6 - View Last Failure
```

Approval, reboot, and interactive-authentication actions appear only when required.

---

# Execution Host Requirements

The approved execution host must have:

```text
PowerShell 7.4 or later
powershell-yaml module
Package root and protected files
Artifact write access
Approved runner profile
Azure CLI for Phase 1.3 and later
Configured module baseline for Phase 1.3 and later
Bicep capability for future Phase 2 planning
```

Execution-host validation runs:

```text
At Deployment Manager startup
During Stage 1.1 execution-host validation
Before later Azure/bootstrap/Arc stages when Azure tooling is required
```

---

# Artifacts and Evidence

## Onboarding Artifacts

```text
artifacts\<SITE>\<run-id>\
  deployment-state.json
  evidence\
  reports\
```

## Read-Only Validation Artifacts

```text
artifacts\<SITE>\validation\<run-id>\
  read-only-validation-state.json
  evidence\
  reports\
    validation-findings.html
    validation-findings.json
```

Keep both report formats:

```text
HTML = operator-readable report
JSON = machine-readable evidence and audit record
```

---

# NRFT Reference-Cluster Restrictions

NRFT is a read-only validation/reference target.

Allowed:

```text
Plan Phase 1
Stage 1.1 validation
1.2A read-only discovery
1.2C read-only compliance validation
NRFT read-only regression tool
Evidence/report review
```

Prohibited:

```text
1.2B Apply
Any Ensure-* execution
Reboot testing
Arc registration
Device-code Arc onboarding
Domain changes
Network/VLAN/IP/DNS/NTP changes
Cluster deployment
Phase 2 through Phase 4 execution
```

Run the NRFT regression tool:

```powershell
.\tools\Test-NRFTReadOnlyRegression.ps1
```

Expected result:

```text
Existing cluster detected
Existing registration detected
No Ensure-* evidence
No pending approval
No pending reboot
Passed = True
```

---

# Phase 1 Script Reference

## Launcher and Workflow Control

| Script | Purpose |
|---|---|
| `Run-AzureLocalDeploymentManager.cmd` | Launches local Deployment Manager and certificate-mode selection |
| `launcher\Start-AzureLocalDeploymentManager.ps1` | Main operator menu, onboarding actions, approvals, resume, and read-only validation access |
| `launcher\Start-ReadOnlyValidation.ps1` | Action 4 submenu for independent 1.2A and 1.2C validation profiles |
| `launcher\Merge-FactoryConfiguration.ps1` | Merges protected defaults, site variables, workflow manifest, and adapter map into resolved configuration |
| `launcher\Test-OperatorWorkstation.ps1` | Validates PowerShell, YAML, package, artifact, Azure CLI/Bicep, module, and runner prerequisites |
| `launcher\Initialize-OperatorSession.ps1` | Collects or initializes approved runtime credentials when required |
| `launcher\Initialize-AzureGovernmentSession.ps1` | Performs Azure Government device-code authentication for Azure/bootstrap/Arc stages |
| `launcher\Set-DeploymentApproval.ps1` | Records operator approval or denial for configuration/reboot actions |
| `launcher\Get-DeploymentManagerStatus.ps1` | Builds manager status display from manifest and evidence state |

## Controller and State

| Script | Purpose |
|---|---|
| `controller\Factory.psm1` | Approved operation catalog, adapter resolution, result handling, manifest/config helpers, and error sanitization |
| `controller\Invoke-AzureLocalFactory.ps1` | Onboarding workflow controller, state persistence, approvals, reboot/reconnect, and stage execution |
| `controller\Invoke-Stage.ps1` | Runs ordered stage operations and handles approval/reboot/interactive pauses |
| `controller\Invoke-ReadOnlyValidation.ps1` | Runs non-mutating profiles, collects findings, and generates reports without onboarding-state advancement |
| `controller\Invoke-NodeRebootAndReconnect.ps1` | Executes approved reboot, waits for WinRM reconnect, and returns evidence |
| `controller\Invoke-Phase.ps1` | Resolves eligible onboarding stages |
| `controller\Invoke-ValidationGate.ps1` | Evaluates stage validation result collection |
| `controller\Get-DeploymentState.ps1` | Deferred/legacy state helper; not used by current primary manager path |
| `controller\Invoke-Remediation.ps1` | Deferred remediation framework; not current Phase 1 execution path |
| `controller\Resume-Onboarding.ps1` | Deferred legacy resume helper; current manager uses factory `-Resume` flow |

## Phase 1.1 Validation

| Script | Purpose |
|---|---|
| `preflight\Test-EnvironmentConfiguration.ps1` | Validates resolved site/cluster/node/workflow structure |
| `preflight\Test-NamingConvention.ps1` | Validates cluster and node naming conventions |
| `preflight\Test-IPAddressAllocation.ps1` | Validates management network, gateway, VLAN, and IP allocation consistency |
| `preflight\Test-StorageNetworkConfiguration.ps1` | Validates storage networks, adapters, VLANs, and node storage assignments |
| `preflight\Test-DnsConfiguration.ps1` | Validates DNS server configuration input |
| `preflight\Test-ActiveDirectoryConfiguration.ps1` | Validates AD domain, SRV, DC, DNS, and port input configuration |
| `preflight\Test-ExecutionHostConfiguration.ps1` | Validates selected execution host is approved for the selected site |
| `preflight\Test-RequiredSecrets.ps1` | Validates secret references/environment variable names, not secret values |
| `preflight\Test-ReleasePackageIntegrity.ps1` | Validates package files against protected release manifest |

## Phase 1.2A Discovery and Readiness

| Script | Purpose |
|---|---|
| `preflight\Get-AzureLocalDeploymentState.ps1` | Read-only inventory of clustered, registered, Azure resource, domain, and reference state |
| `preflight\Test-RemoteManagement.ps1` | Validates management-plane WinRM connectivity |
| `preflight\Test-WinRMCertificateTrust.ps1` | Reports strict or temporary WinRM certificate validation mode |
| `preflight\Test-NodeIdentity.ps1` | Validates current node identity/domain/workgroup state |
| `bootstrap\os\Test-AzureLocalOS.ps1` | Detects Azure Local OS |
| `bootstrap\os\Test-AzureLocalPolicyState.ps1` | Validates Azure Local policy/support state |
| `preflight\Test-HardwareReadiness.ps1` | Collects processor, disk, and hardware readiness data |
| `preflight\Test-NICState.ps1` | Collects active NIC state and adapter inventory |
| `preflight\Test-MellanoxDriverBaseline.ps1` | Validates Mellanox driver baseline |
| `preflight\Test-TpmReadiness.ps1` | Validates TPM presence/readiness |
| `preflight\Test-SecureBoot.ps1` | Validates Secure Boot |
| `preflight\Test-RequiredWindowsFeatures.ps1` | Validates required Windows features |
| `preflight\Test-AzureLocalOfficialConnectivityValidation.ps1` | Runs/captures official Azure Local connectivity readiness validation |
| `preflight\Test-AzureLocalOfficialHardwareValidation.ps1` | Runs/captures official Azure Local hardware readiness validation |

## Phase 1.2B Ensure Desired State

| Script | Purpose |
|---|---|
| `preflight\Test-AzureLocalDeploymentState.ps1` | Onboarding safety gate; blocks clustered or registered targets before mutation |
| `bootstrap\os\Ensure-NicRoleMapping.ps1` | Ensures NIC aliases match approved hardware mapping |
| `bootstrap\os\Ensure-EmbeddedAdaptersDisabled.ps1` | Ensures embedded adapters are in approved inactive state |
| `bootstrap\os\Ensure-DhcpDisabled.ps1` | Disables DHCP on approved deployment adapters |
| `bootstrap\os\Ensure-ManagementVlan.ps1` | Ensures management VLAN matches site configuration |
| `bootstrap\os\Ensure-ManagementNetwork.ps1` | Ensures management IP/prefix/gateway match approved site values |
| `bootstrap\os\Ensure-DNS.ps1` | Ensures DNS servers match approved site values |
| `bootstrap\os\Ensure-NTP.ps1` | Ensures approved NTP configuration |
| `bootstrap\os\Ensure-StorageNetwork.ps1` | Ensures storage addressing and VLAN configuration |
| `bootstrap\os\Ensure-IPv6Baseline.ps1` | Ensures IPv6 registry and binding baseline; may require reboot |
| `bootstrap\os\Ensure-LocalDeploymentAdministrator.ps1` | Ensures bootstrap local deployment account state |
| `bootstrap\os\Ensure-PowerShellRemoting.ps1` | Ensures PowerShell remoting desired state |
| `bootstrap\os\Ensure-HostName.ps1` | Ensures hostname; may require reboot |

## Phase 1.2C Compliance Validation

| Script | Purpose |
|---|---|
| `preflight\Test-LocalAdministratorReadiness.ps1` | Validates bootstrap account lifecycle, local admin membership, or expected lifecycle absence |
| `preflight\Test-LocalAdministratorCredential.ps1` | Validates credential when policy requires it; otherwise reports deferred/not-applicable state |
| `preflight\Test-AdapterDesignState.ps1` | Validates NIC mapping, required enabled adapters, and approved inactive embedded adapter state |
| `preflight\Test-DhcpState.ps1` | Validates DHCP state |
| `preflight\Test-ManagementVlanState.ps1` | Validates management VLAN |
| `preflight\Test-IPConfiguration.ps1` | Validates management addressing and interface configuration |
| `preflight\Test-Gateway.ps1` | Validates default gateway |
| `preflight\Test-DNS.ps1` | Validates configured DNS server state |
| `preflight\Test-NTP.ps1` | Validates NTP source, peers, and time state |
| `preflight\Test-StorageNetworkReadiness.ps1` | Validates storage network addressing/readiness |
| `preflight\Test-RdmaState.ps1` | Validates RDMA state |
| `preflight\Test-SriovState.ps1` | Validates SR-IOV state |
| `preflight\Test-IPv6Baseline.ps1` | Validates IPv6 registry and adapter binding state |
| `preflight\Test-ActiveDirectoryReadiness.ps1` | Validates AD/DNS/DC/port readiness |
| `preflight\Test-TpmReadiness.ps1` | Validates TPM state |
| `preflight\Test-SecureBoot.ps1` | Validates Secure Boot |
| `preflight\Test-RequiredWindowsFeatures.ps1` | Validates required Windows features |

## Phase 1.3 Bootstrap Readiness

| Script | Purpose |
|---|---|
| `azure\preparation\Connect-Azure.ps1` | Validates Azure Government CLI context |
| `azure\preparation\Test-Subscription.ps1` | Validates subscription state |
| `azure\preparation\Test-Permissions.ps1` | Validates required Azure read/query permissions |
| `azure\preparation\Test-ResourceProviders.ps1` | Validates required resource providers |
| `azure\preparation\Test-ResourceGroup.ps1` | Validates target resource group |
| `preflight\Test-AzureConnectivity.ps1` | Validates Azure endpoint connectivity |
| `preflight\Test-AzureGovEndpoints.ps1` | Validates configured Azure Government endpoints |
| `bootstrap\os\Test-AzureLocalNodeBootstrapState.ps1` | Validates node remains unclustered/unregistered and bootstrap-ready |

## Phase 1.4 Arc Registration

| Script | Purpose |
|---|---|
| `azure\registration\Test-AzureRegistrationInputs.ps1` | Validates Azure Government, user/device-code Arc configuration, resource group, and registration mode |
| `azure\registration\Invoke-AzureLocalArcInitialization.ps1` | Validates Connected Machine agent/HIMDS readiness and blocks unsafe existing cluster/registration state |
| `azure\registration\Register-ArcNode.ps1` | Starts approved interactive device-code Arc registration or reports readiness-only block |
| `azure\registration\Test-ArcRegistration.ps1` | Validates Arc resource visibility and local agent/HIMDS state |
| `validation\Test-NodeHealth.ps1` | Validates node health |
| `validation\Test-ArcHealth.ps1` | Validates Azure Arc health |

## Reporting and Evidence

| Script | Purpose |
|---|---|
| `reports\New-ValidationFindingsReport.ps1` | Generates HTML and JSON findings reports for read-only validation profiles |
| `reports\New-DeploymentReport.ps1` | Generates end-of-workflow deployment report |
| `tools\New-ReleaseManifest.ps1` | Generates protected release manifest hashes |
| `tools\Test-Phase12AdapterReadiness.ps1` | Validates Phase 1.1/1.2 catalog, mappings, file existence, and syntax |
| `tools\Test-Batch2BApprovalEngineReadiness.ps1` | Validates approval/pause/resume engine readiness |
| `tools\Test-NRFTReadOnlyRegression.ps1` | Validates NRFT read-only mutation protection and evidence behavior |

---

# Phase 1 Completion Criteria

Phase 1 is complete when:

```text
1.1 passes
1.2B completes successfully on approved vanilla nodes
1.2C reports compliant final desired state
1.3 readiness passes
Each node is Azure Arc-enabled
Each node is visible in the Azure portal
Test-ArcRegistration passes
Test-NodeHealth passes
Test-ArcHealth passes
Evidence and reports are retained
No Azure Local cluster is created
```