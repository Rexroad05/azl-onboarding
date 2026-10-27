#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

function New-TemporaryStatePath {
    $directory = Join-Path `
        $env:TEMP `
        ("azure-local-pester-" + [guid]::NewGuid().ToString('N'))

    New-Item `
        -ItemType Directory `
        -Path $directory `
        -Force |
        Out-Null

    return Join-Path `
        $directory `
        'deployment-state.json'
}

function Write-TestState {
    param(
        [Parameter(Mandatory)]
        [hashtable]$State,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $State |
        ConvertTo-Json -Depth 50 |
        Set-Content `
            -LiteralPath $Path `
            -Encoding utf8
}

function Read-TestState {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (
        Get-Content `
            -LiteralPath $Path `
            -Raw |
            ConvertFrom-Json `
                -AsHashtable
    )
}

$approvalScript = Get-TestRepositoryPath `
    -RelativePath 'launcher\Set-DeploymentApproval.ps1'

Describe 'Approval and Reboot Behavioral Simulation' {
    It 'approves a legacy configuration request without ApprovalType' {
        $statePath = New-TemporaryStatePath

        try {
            $state = @{
                status = 'PAUSED'
                approvedOperations = @{}
                pendingReboot = $null
                pendingApproval = @{
                    ApprovalKey = '1.2.TESTHCN01.Ensure-DNS'
                    PhaseId = 1
                    StageId = 2
                    Operation = 'Ensure-DNS'
                    Node = 'TESTHCN01'
                    Reason = 'Simulated DNS change.'
                }
            }

            Write-TestState `
                -State $state `
                -Path $statePath

            $result = & $approvalScript `
                -StatePath $statePath `
                -Decision Approve

            $updated = Read-TestState `
                -Path $statePath

            $result.Decision |
                Should Be 'Approve'

            $result.ApprovalType |
                Should Be 'ConfigurationChange'

            $updated.status |
                Should Be 'APPROVED'

            $updated.pendingApproval.ApprovalType |
                Should Be 'ConfigurationChange'

            $updated.approvedOperations.Contains(
                '1.2.TESTHCN01.Ensure-DNS'
            ) |
                Should Be $true
        }
        finally {
            Remove-Item `
                -LiteralPath (Split-Path $statePath -Parent) `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'preserves focused native Arc resume state when approving registration' {
        $statePath = New-TemporaryStatePath

        try {
            $approvalKey = (
                '1.4.TESTHCN01.NativeAzureLocalArcBootstrap'
            )

            $state = @{
                status = 'PAUSED'
                runId = 'PesterNativeArcRun'
                returnToPhase = 1
                returnToStage = 4
                returnToOperation = 'Register-ArcNode'
                approvedOperations = @{}
                pendingReboot = $null
                pendingInteractiveAuthentication = $null
                operationCheckpoints = @{
                    '1.4' = @{
                        'Site::Connect-Azure' = @{
                            status = 'PASS'
                        }
                    }
                }
                pendingApproval = @{
                    ApprovalKey = $approvalKey
                    ApprovalType = 'ConfigurationChange'
                    PhaseId = 1
                    StageId = 4
                    Operation = 'Register-ArcNode'
                    Node = 'TESTHCN01'
                    Reason = 'Native Arc registration requires approval.'
                    ReturnToOperation = 'Register-ArcNode'
                }
            }

            Write-TestState `
                -State $state `
                -Path $statePath

            $result = & $approvalScript `
                -StatePath $statePath `
                -Decision Approve

            $updated = Read-TestState `
                -Path $statePath

            $result.Decision |
                Should Be 'Approve'

            $result.ApprovalKey |
                Should Be $approvalKey

            $updated.status |
                Should Be 'APPROVED'

            $updated.returnToOperation |
                Should Be 'Register-ArcNode'

            $updated.pendingApproval.ReturnToOperation |
                Should Be 'Register-ArcNode'

            $updated.operationCheckpoints.Contains('1.4') |
                Should Be $true

            $updated.approvedOperations.Contains($approvalKey) |
                Should Be $true
        }
        finally {
            Remove-Item `
                -LiteralPath (Split-Path $statePath -Parent) `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'approves a reboot request and updates pendingReboot state' {
        $statePath = New-TemporaryStatePath

        try {
            $approvalKey = (
                '1.2.TESTHCN01.Ensure-HostName.Reboot'
            )

            $state = @{
                status = 'PAUSED'
                approvedOperations = @{}
                pendingApproval = @{
                    ApprovalKey = $approvalKey
                    ApprovalType = 'Reboot'
                    PhaseId = 1
                    StageId = 2
                    Operation = 'Ensure-HostName'
                    Node = 'TESTHCN01'
                    Reason = 'Hostname change requires reboot.'
                    ReconnectTarget = 'TESTHCN01'
                }
                pendingReboot = @{
                    ApprovalKey = $approvalKey
                    ApprovalType = 'Reboot'
                    PhaseId = 1
                    StageId = 2
                    Operation = 'Ensure-HostName'
                    Node = 'TESTHCN01'
                    Reason = 'Hostname change requires reboot.'
                    ReconnectTarget = 'TESTHCN01'
                    Status = 'PENDING_APPROVAL'
                }
            }

            Write-TestState `
                -State $state `
                -Path $statePath

            $result = & $approvalScript `
                -StatePath $statePath `
                -Decision Approve

            $updated = Read-TestState `
                -Path $statePath

            $result.Decision |
                Should Be 'Approve'

            $result.ApprovalType |
                Should Be 'Reboot'

            $updated.status |
                Should Be 'APPROVED'

            $updated.pendingReboot.Status |
                Should Be 'APPROVED'

            $updated.pendingReboot.Decision |
                Should Be 'Approved'

            $updated.approvedOperations.Contains($approvalKey) |
                Should Be $true
        }
        finally {
            Remove-Item `
                -LiteralPath (Split-Path $statePath -Parent) `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'denies a reboot request and records denial state' {
        $statePath = New-TemporaryStatePath

        try {
            $state = @{
                status = 'PAUSED'
                approvedOperations = @{}
                pendingApproval = @{
                    ApprovalKey = (
                        '1.2.TESTHCN01.Ensure-IPv6Baseline.Reboot'
                    )
                    ApprovalType = 'Reboot'
                    PhaseId = 1
                    StageId = 2
                    Operation = 'Ensure-IPv6Baseline'
                    Node = 'TESTHCN01'
                    Reason = 'IPv6 change requires reboot.'
                }
                pendingReboot = @{
                    ApprovalKey = (
                        '1.2.TESTHCN01.Ensure-IPv6Baseline.Reboot'
                    )
                    ApprovalType = 'Reboot'
                    Node = 'TESTHCN01'
                    Status = 'PENDING_APPROVAL'
                }
            }

            Write-TestState `
                -State $state `
                -Path $statePath

            $result = & $approvalScript `
                -StatePath $statePath `
                -Decision Deny

            $updated = Read-TestState `
                -Path $statePath

            $result.Decision |
                Should Be 'Deny'

            $updated.status |
                Should Be 'DENIED'

            $updated.pendingReboot.Status |
                Should Be 'DENIED'

            $updated.pendingReboot.Decision |
                Should Be 'Denied'
        }
        finally {
            Remove-Item `
                -LiteralPath (Split-Path $statePath -Parent) `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'rejects approval actions when state is not paused' {
        $statePath = New-TemporaryStatePath

        try {
            $state = @{
                status = 'RUNNING'
                approvedOperations = @{}
                pendingApproval = @{
                    ApprovalKey = '1.2.TESTHCN01.Ensure-DNS'
                }
            }

            Write-TestState `
                -State $state `
                -Path $statePath

            $threw = $false
            $capturedError = $null

            try {
                & $approvalScript `
                    -StatePath $statePath `
                    -Decision Approve
            }
            catch {
                $threw = $true
                $capturedError = $_
            }

            $threw |
                Should Be $true

            $capturedError |
                Should Not BeNullOrEmpty
        }
        finally {
            Remove-Item `
                -LiteralPath (Split-Path $statePath -Parent) `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'contains an approved remote reboot path and reconnect timeout control' {
        $rebootHelper = Get-TestFileContent `
            -RelativePath 'controller\Invoke-NodeRebootAndReconnect.ps1'

        $rebootHelper |
            Should Match 'Invoke\-ApprovedNodeReboot'

        $rebootHelper |
            Should Match 'New\-ManagementPlaneSession'

        $rebootHelper |
            Should Match 'ReconnectTimeoutSeconds'

        $rebootHelper |
            Should Match 'did not reconnect through WinRM within'
    }
}