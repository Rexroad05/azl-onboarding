# Site adapter contract
Each operation not listed as built-in in IMPLEMENTATION-STATUS.md requires a PowerShell adapter. Add its path to environment YAML:

```yaml
adapters:
  Test-RemoteManagement: adapters/windows/Test-HostRemoting.ps1
  Test-ClusterHealth: adapters/windows/Test-ClusterHealth.ps1
  Test-StorageHealth: adapters/windows/Test-StorageHealth.ps1
```

Adapters accept `param([Parameter(Mandatory)]$Context)` and return exactly one object with a Boolean `Passed`. Throw or return Passed=false to fail. Send incidental diagnostics with Write-Verbose, not success-stream output. Never output passwords, tokens, ISO SAS URLs or deployment parameters. Context contains Root, Config, Mode, RunId, RunDirectory and State. Put sanitized evidence under RunDirectory/evidence. Write JSON atomically using Write-FactoryJson. No implicit success for skipped operations.

Mutation adapters must enforce Apply mode, verify identity and current state before changing it, poll task completion with a bounded timeout, and verify desired state afterwards. An accepted HTTP response is not completed configuration. Reboots, iDRAC task jobs and OS installation need model-specific completion handling. Retries are disabled by default because blindly repeating installation or deployment is unsafe. Enable retries only for operations reviewed as idempotent.

Use a trusted controller identity for WinRM HTTPS; the host adapter examples use current process credentials and do not alter TrustedHosts. Install host and iDRAC certificates trusted by the controller. Discovery compares service tags before proceeding. DHCP discovery requires a site DHCP lease lookup adapter to map service tags/MACs to addresses; the built-in discovery uses explicitly supplied iDRAC addresses.

Supply an Install-AzureLocalOS adapter and wire it into stage 3 only after testing unattended installation with your exact approved media. The default stage 3 validates an existing remotely manageable OS. BIOS stages likewise validate only; add Set-BIOSBaseline before tests if its model-specific adapter is complete. This default prevents an untested adapter from wiping machines.

## Current Workflow Supersession

The current deployment workflow is manifest-driven. Authoritative operation mappings are maintained in `protected/adapters.yaml`; stage sequencing is maintained in `protected/phase-manifest.yaml`. Legacy `adapters/windows` mappings were archived and are not part of the active package.