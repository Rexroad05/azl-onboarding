# Implementation status
This is a gated implementation baseline, not a production-tested turnkey deployment.

| Area | Supplied behavior | Remaining work |
|---|---|---|
| Controller | Plan, run lock, atomic state, bounded attempts, resume, configuration hash guard | Test under Windows PowerShell 7.4 and abrupt power loss; add site-wide locking if multiple controllers run |
| Discovery | TCP 443 check, Redfish Systems inventory, service tag identity check | DHCP lease lookup, comprehensive inventory, iDRAC trust/credentials |
| Hardware | Entry points and fail-closed adapter contract | Validated model-specific Dell BIOS and firmware adapters and polling |
| OS | Entry points, WinRM HTTPS example | Unattended media/install, hostname/IP handoff, DNS/NTP and remoting bootstrap |
| Preflight | Entry points and adapter contract | Host-side connectivity, network/storage design tests and current Microsoft environment checker |
| Azure preparation | Existing context, subscription, RG and provider readiness checks | Authentication setup, role validation; provider check does not register providers |
| Registration | Connected-state check | Official Azure Local node registration adapter |
| Deployment | Validate and submit supplied ARM template via Azure CLI | Version-matched Microsoft template, parameter file, long-running readiness checks |
| Services | Existing bridge and custom location checks | Storage paths/logical networks, service readiness adapter |
| Validation | Cluster/storage example adapters and operation entry points | Full node, Arc and control plane validation |
| Workload | Entry points and adapter contract | Exact gallery image/network/VM deployment and guest network tests |
| Reports | JSON state and certification output | Optional HTML renderer; supplied HTML is a template |
| Tests | Python package structural check and Pester fail-closed tests | Execute Pester and lab integration on Windows |

The gates intentionally stop on missing adapters. All script paths from the proposed tree exist. Wrappers are entry points into the shared module; they are not independent implementations of hardware or installation behavior. No hardware operations, Azure deployments or remote tests were executed while building this package.

## Legacy Workflow Archive

The legacy gate, baseline, generic adapter, and imperative setter workflow was archived. Phase 1.1 and 1.2 now use the manifest-driven idempotent `Ensure-*` workflow and approval/pause/resume state model.