#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

function Get-NodeIdentityValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return Get-ManagementPlaneValue `
        -Object $Object `
        -Name $Name
}

$activeDirectory = Get-NodeIdentityValue `
    -Object $Context.Config `
    -Name 'active_directory'

$requireWorkgroup = [bool](
    Get-NodeIdentityValue `
        -Object $activeDirectory `
        -Name 'require_prebootstrap_workgroup_state'
)

$expectedNodeName = [string](
    Get-NodeIdentityValue `
        -Object $Context.Node `
        -Name 'name'
)

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-NodeIdentity' `
    -ScriptBlock {
        $computerSystem = Get-CimInstance `
            -ClassName Win32_ComputerSystem `
            -ErrorAction Stop

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Domain = [string]$computerSystem.Domain
            PartOfDomain = [bool]$computerSystem.PartOfDomain
        }
    }

$data = @($result.Data) |
    Select-Object -First 1

if (
    -not [string]::IsNullOrWhiteSpace($expectedNodeName) -and
    $data.ComputerName -ne $expectedNodeName
) {
    throw (
        "Node identity mismatch. Expected '$expectedNodeName'; " +
        "observed '$($data.ComputerName)'."
    )
}

if ($requireWorkgroup -and $data.PartOfDomain) {
    throw (
        "Node $($data.ComputerName) is joined to domain '$($data.Domain)'. " +
        'Pre-bootstrap workgroup state is required.'
    )
}

$classification = if ($data.PartOfDomain) {
    'ReferenceDifference'
}
else {
    'Compliant'
}

$summary = if ($data.PartOfDomain) {
    (
        "Node identity validated. Node is joined to domain $($data.Domain). " +
        'This is reported as a reference/deployed-state difference.'
    )
}
else {
    (
        "Node identity validated. Node is in workgroup state '$($data.Domain)'."
    )
}

return [pscustomobject]@{
    Passed         = $true
    Check          = 'Test-NodeIdentity'
    Outcome        = 'AlreadyCompliant'
    Classification = $classification
    Node           = $result.Node
    ManagementIp   = $result.ManagementIp
    ConnectionHost = $result.ConnectionHost
    ConnectionPort = $result.ConnectionPort
    ComputerName   = $data.ComputerName
    Domain         = $data.Domain
    PartOfDomain   = $data.PartOfDomain
    Summary        = $summary
    ValidatedAt    = [datetime]::UtcNow.ToString('o')
}