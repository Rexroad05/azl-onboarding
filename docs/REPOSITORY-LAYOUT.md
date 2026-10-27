# Repository layout

- controller/: runtime entry points, orchestration, state and gate execution.
- adapters/dell/hardware/: Dell discovery, inventory, firmware/BIOS checks, BIOS changes and readiness; shared DellHardware.Common.psm1 stays here.
- adapters/dell/media/: ISO mounting, one-time boot and restart; shared DellVirtualMedia.Common.psm1 stays here.
- adapters/windows/: Windows remoting, cluster and storage checks.
- adapters/examples/: development examples, not deployed implementations.
- bootstrap/, preflight/, azure/, validation/, workload/: named workflow entry points. Preserve these wrappers; they delegate through Factory.psm1.
- environments/: active site configuration, including NRFT.yaml.
- config/examples/: mapping/media samples, not automatically loaded.
- config/hardware-baselines/: approved baselines and examples.
- config/azure-endpoints/: endpoint configuration.
- config/workflow/: reference workflow template; execution uses workflow.stages in the selected environment YAML.
- tools/maintenance/: one-time repository updates, including the dispatcher patch.
- tests/unit/: Pester tests. tests/check_package.py stays at tests/.
- docs/verification/: original package-build evidence, not proof of current runtime readiness.
- artifacts/: gitignored runtime plans, state, logs and evidence. Never reorganize a live run or rewrite historical state hashes.

Start commands from the repository root:

```powershell
.\controller\Invoke-DellHardwareBootstrap.ps1 -Environment .\environments\NRFT.yaml -Phase Discovery -Mode Validate -RunDirectory C:\FactoryRuns\NRFT\hardware-002
.\controller\Invoke-DellMediaBootstrap.ps1 -Environment .\environments\NRFT.yaml -Action Mount -Mode Plan -RunDirectory C:\FactoryRuns\NRFT\media-002
.\controller\Invoke-AzureLocalFactory.ps1 -Environment .\environments\NRFT.yaml -Mode Plan
Invoke-Pester .\tests\unit -Output Detailed
```

After relocation, run tools/maintenance/Update-FactoryHardwareDispatch.ps1 if the adapter-precedence patch has not already been applied. The patch is idempotent. Relocation does not install missing stage implementations or run hardware actions.

Environment values are preserved; path strings are updated in place without YAML reserialization. Changed YAML produces a new configuration hash: start a new factory run rather than rewriting an existing run's hash. Historical artifacts are preserved.

## Current Workflow Layout

The active workflow uses `protected/phase-manifest.yaml`, `protected/adapters.yaml`, `controller/`, `launcher/`, `preflight/`, and `bootstrap/os/Ensure-*`. Legacy numbered gate scripts, generic Windows adapters, and imperative setter scripts are archived under `archive/`.