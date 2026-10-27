# Bootstrap-Local WinRM Remoting

## Purpose

This document defines the approved Phase 1 connection pattern for an Azure Local
node that is reachable through an approved external bootstrap endpoint before
the node is joined to Active Directory Domain Services (AD DS).

This pattern supports vanilla Azure Local onboarding and read-only validation
without requiring the factory to treat the external endpoint as the node's
internal management-plane address.

## Scope

This connection mode is limited to Phase 1 activities, including:

- 1.1 input and build validation;
- 1.2A HCN discovery and readiness validation;
- 1.2B Ensure HCN Desired State;
- 1.2C HCN compliance validation;
- 1.3 Azure Local node bootstrap readiness validation; and
- 1.4 Azure Arc registration when separately approved and enabled.

It does not authorize cluster deployment, host configuration changes outside
the approved workflow, or Phase 2 execution.

## Site Variable Configuration

A node uses bootstrap-local remoting only when its approved site variables
contain `bootstrap_connection`.

```yaml
nodes:
  - name: AZL-CNEF-N1
    management:
      ip_address: 192.168.1.189
      prefix_length: 24
      gateway: 192.168.1.1

    bootstrap_connection:
      host: AZL-CNEF-N1
      port: 5986

      ## In-Workflow Temporary Certificate Exception

Read-only bootstrap validation defaults to strict WinRM HTTPS certificate validation.

For a bootstrap-local node whose server certificate chain is not yet trusted by
the execution host, the read-only launcher can offer a temporary exception only
when protected configuration permits it:

```yaml
remote_management:
  allow_temporary_certificate_exception: true