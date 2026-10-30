# Azure Local Deployment Manager Quick Start

## Purpose

The Azure Local Deployment Manager guides the approved Phase 1 Azure Local onboarding workflow for a selected site. It tracks workflow state, approvals, reboots, evidence, and run-scoped deployment reports.

Use the manager for normal workflow progression. Do not manually edit deployment state, approval records, reports, or evidence unless directed through approved troubleshooting procedures.

---

## Primary Workflow

Phase 1 executes in this order:

1. **Stage 1.1 - Input and Build Validation**
   - Validates site inputs, naming, IP allocation, package integrity, and build readiness.
   - Read-only validation.
   - No node configuration changes are made.

2. **Stage 1.2B - Ensure HCN Desired State**
   - Inspects node configuration.
   - Requests approval before applying configuration changes.
   - May require a controlled reboot and reconnect.
   - Records Changed, Skipped, Passed, Paused, or Failed outcomes.

3. **Stage 1.3 - Azure Local Node Bootstrap Readiness**
   - Validates Azure Government authentication, subscription, providers, resource group, Azure endpoints, and node readiness.
   - Read-only validation.

4. **Stage 1.4 - Azure Arc Machine Registration and Validation**
   - Validates prerequisites.
   - Requests approval before native Azure Local Arc registration.
   - Uses the factory-owned Native Arc Registration Session.
   - Validates Arc resource registration, HIMDS, and node health.

---

## Main Menu

### 1 - Continue Recommended Workflow Action

Use this for the normal workflow path.

The manager determines the next appropriate action based on saved workflow state:

- Run the next ready validation stage.
- Request confirmation before applying a configuration-changing stage.
- Approve a pending configuration change or reboot.
- Start or resume the Native Arc Registration Session.
- Resume an approved workflow after a controlled reboot.

### 2 - Plan Current/Next Stage

Creates a plan-only run for the current or next executable stage.

Plan mode does not execute node operations or configuration changes. It records the intended operations in the run artifact directory and generates a deployment report.

### 3 - Show Current Workflow Status

Displays all implemented stages and their current status, including any native Azure Arc registration session details.

### 4 - Run Read-Only Validation

Runs the supported read-only validation workflow and produces validation findings artifacts.

### 5 - View Last Failure and Evidence

Displays the latest recorded onboarding failure, including stage, timestamp, sanitized reason, and evidence location.

### 6 - Show Workflow Map

Displays the workflow sequence and overlays current stage status.

### 7 - Advanced Actions

Provides planning, raw state, native Arc status, and deployment report actions.

### 8 - Help and Deployment Manager SOP

Displays this README, opens the formatted SOP, or shows report and evidence locations.

### 9 - Exit

Exits the manager and clears session-scoped credential environment variables.

---

## Status Meanings

| Status | Meaning |
|---|---|
| PASSED | Operation or stage completed successfully without requiring a reported configuration change. |
| SKIPPED | Desired state already existed or no action was required. |
| CHANGED | Desired state was successfully modified. |
| PAUSED | Operator action, approval, reboot, or interactive authentication is required before continuation. |
| FAILED | An operation or validation failed. Review sanitized failure evidence. |
| BLOCKED | Workflow cannot continue until the recorded failure is resolved through approved procedures. |
| READY | The stage is unlocked and can be executed. |
| LOCKED | Prerequisite stage evidence is not yet complete. |

---

## Approval and Reboot Handling

When a configuration change, reboot, or native Arc registration requires approval:

1. Review the displayed operation, node, and reason.
2. Use **Continue Recommended Workflow Action**.
3. Type the required approval confirmation exactly as prompted.
4. Allow the manager to preserve state and resume the workflow.
5. Do not manually alter approval state files.

A reboot pause is deliberate. The workflow will record reboot evidence, reconnect to the node, and continue validation after the approved reboot completes.

---

## Native Arc Registration Session

Stage 1.4 uses the factory-owned native Azure Local Arc bootstrap workflow.

The Deployment Manager may display:

- Native bootstrap status.
- Current node.
- Last status-check time.
- Pending approval state.
- Interactive authentication pause state.

Use **Continue Recommended Workflow Action** to start or resume the Native Arc Registration Session. Do not start a separate manual node-side registration workflow while the factory session is active.

---

## Reports and Evidence

Every factory run produces run-scoped artifacts under:

```text
artifacts\<site>\<RunId>\