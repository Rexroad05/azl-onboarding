#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$activeDirectory = Get-ManagementPlaneValue `
    -Object $Context.Config `
    -Name 'active_directory'

$azure = Get-ManagementPlaneValue `
    -Object $Context.Config `
    -Name 'azure'

$identityMode = [string](
    Get-ManagementPlaneValue `
        -Object $activeDirectory `
        -Name 'identity_mode'
)

$requireWorkgroupState = Get-ManagementPlaneValue `
    -Object $activeDirectory `
    -Name 'require_prebootstrap_workgroup_state'

if ($identityMode -eq 'LocalIdentityWithKeyVault') {
    $keyVault = Get-ManagementPlaneValue `
        -Object $azure `
        -Name 'key_vault'

    $keyVaultName = [string](
        Get-ManagementPlaneValue `
            -Object $keyVault `
            -Name 'name'
    )

    $keyVaultResourceGroup = [string](
        Get-ManagementPlaneValue `
            -Object $keyVault `
            -Name 'resource_group'
    )

    $keyVaultResourceId = [string](
        Get-ManagementPlaneValue `
            -Object $keyVault `
            -Name 'resource_id'
    )

    if (
        [string]::IsNullOrWhiteSpace($keyVaultName) -or
        [string]::IsNullOrWhiteSpace($keyVaultResourceGroup) -or
        [string]::IsNullOrWhiteSpace($keyVaultResourceId)
    ) {
        throw (
            'Local Identity readiness requires Azure Key Vault name, resource group, and resource ID.'
        )
    }

    $result = Invoke-ManagementPlaneCommand `
        -Context $Context `
        -OperationName 'Test-ActiveDirectoryReadiness' `
        -ArgumentList @(
            [bool]$requireWorkgroupState,
            $keyVaultName,
            $keyVaultResourceGroup,
            $keyVaultResourceId
        ) `
        -ScriptBlock {
            param(
                [bool]$RequireWorkgroupState,
                [string]$KeyVaultName,
                [string]$KeyVaultResourceGroup,
                [string]$KeyVaultResourceId
            )

            $computerSystem = Get-CimInstance `
                -ClassName Win32_ComputerSystem `
                -ErrorAction Stop

            if (
                $RequireWorkgroupState -and
                $computerSystem.PartOfDomain
            ) {
                throw (
                    "Expected Local Identity workgroup state, but node is joined " +
                    "to domain $($computerSystem.Domain)."
                )
            }

            [pscustomobject]@{
                ComputerName          = $env:COMPUTERNAME
                Domain                = $computerSystem.Domain
                PartOfDomain          = $computerSystem.PartOfDomain
                KeyVaultName          = $KeyVaultName
                KeyVaultResourceGroup = $KeyVaultResourceGroup
                KeyVaultResourceId    = $KeyVaultResourceId
            }
        }

    $data = @($result.Data) |
        Select-Object -First 1

    return [pscustomobject]@{
        Passed                   = $true
        Check                    = 'Test-ActiveDirectoryReadiness'
        Node                     = $result.Node
        ManagementIp             = $result.ManagementIp
        IdentityMode             = $identityMode
        Domain                   = $data.Domain
        PartOfDomain             = $data.PartOfDomain
        KeyVaultName             = $data.KeyVaultName
        KeyVaultResourceGroup    = $data.KeyVaultResourceGroup
        KeyVaultResourceId       = $data.KeyVaultResourceId
        Summary                  = (
            'Local Identity readiness validated. Node is in approved workgroup ' +
            'state and Azure Key Vault metadata is present.'
        )
        ValidatedAt              = [datetime]::UtcNow.ToString('o')
    }
}

$dnsConfiguration = Get-ManagementPlaneValue `
    -Object $Context.Config `
    -Name 'dns'

$domainFqdn = [string](
    Get-ManagementPlaneValue `
        -Object $activeDirectory `
        -Name 'domain_fqdn'
)

$srvRecord = [string](
    Get-ManagementPlaneValue `
        -Object $activeDirectory `
        -Name 'srv_record'
)

$validationDomainController = [string](
    Get-ManagementPlaneValue `
        -Object $activeDirectory `
        -Name 'validation_domain_controller'
)

$requiredPorts = @(
    Get-ManagementPlaneValue `
        -Object $activeDirectory `
        -Name 'required_ports'
)

$allowedDnsServers = @(
    Get-ManagementPlaneValue `
        -Object $dnsConfiguration `
        -Name 'allowed_servers'
)

if ([string]::IsNullOrWhiteSpace($domainFqdn)) {
    throw 'active_directory.domain_fqdn is required.'
}

if ([string]::IsNullOrWhiteSpace($srvRecord)) {
    throw 'active_directory.srv_record is required.'
}

if ([string]::IsNullOrWhiteSpace($validationDomainController)) {
    throw 'active_directory.validation_domain_controller is required.'
}

if ($allowedDnsServers.Count -lt 1) {
    throw 'dns.allowed_servers must contain at least one DNS server.'
}

if ($requiredPorts.Count -lt 1) {
    throw 'active_directory.required_ports must contain at least one port.'
}

$validationDnsServer = [string]$allowedDnsServers[0]

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-ActiveDirectoryReadiness' `
    -ArgumentList @(
        $domainFqdn,
        $srvRecord,
        $validationDomainController,
        $validationDnsServer,
        [bool]$requireWorkgroupState,
        [int[]]$requiredPorts
    ) `
    -ScriptBlock {
        param(
            [string]$DomainFqdn,
            [string]$SrvRecord,
            [string]$ValidationDomainController,
            [string]$ValidationDnsServer,
            [bool]$RequireWorkgroupState,
            [int[]]$RequiredPorts
        )

        $computerSystem = Get-CimInstance `
            -ClassName Win32_ComputerSystem `
            -ErrorAction Stop

        if (
            $RequireWorkgroupState -and
            $computerSystem.PartOfDomain
        ) {
            throw (
                "Expected pre-bootstrap workgroup state, but node is already " +
                "joined to domain $($computerSystem.Domain)."
            )
        }

        $publicDnsResult = Resolve-DnsName `
            -Name 'www.microsoft.com' `
            -Server $ValidationDnsServer `
            -ErrorAction Stop |
            Select-Object -First 1

        $srvRecords = @(
            Resolve-DnsName `
                -Name $SrvRecord `
                -Type SRV `
                -Server $ValidationDnsServer `
                -ErrorAction Stop
        )

        if ($srvRecords.Count -lt 1) {
            throw (
                "No SRV records were returned for $SrvRecord using DNS server " +
                "$ValidationDnsServer."
            )
        }

        $nltestOutput = @(
            & nltest "/dsgetdc:$DomainFqdn" 2>&1
        )

        if ($LASTEXITCODE -ne 0) {
            throw (
                "nltest failed to locate domain controller for $DomainFqdn. " +
                "Output: $($nltestOutput -join '; ')"
            )
        }

        $portResults = [System.Collections.Generic.List[object]]::new()

        foreach ($port in $RequiredPorts) {
            $connection = Test-NetConnection `
                -ComputerName $ValidationDomainController `
                -Port $port `
                -WarningAction SilentlyContinue

            $portResults.Add([pscustomobject]@{
                ComputerName     = $ValidationDomainController
                RemotePort       = $port
                TcpTestSucceeded = $connection.TcpTestSucceeded
            })
        }

        $failedPorts = @(
            $portResults |
                Where-Object {
                    -not $_.TcpTestSucceeded
                }
        )

        if ($failedPorts.Count -gt 0) {
            throw (
                "Active Directory port validation failed for " +
                "$ValidationDomainController. Failed ports: " +
                (($failedPorts.RemotePort) -join ', ')
            )
        }

        [pscustomobject]@{
            ComputerName            = $env:COMPUTERNAME
            Domain                  = $computerSystem.Domain
            PartOfDomain            = $computerSystem.PartOfDomain
            DnsValidationServer     = $ValidationDnsServer
            PublicDnsName           = $publicDnsResult.Name
            SrvRecord               = $SrvRecord
            SrvRecordCount          = $srvRecords.Count
            DomainController        = $ValidationDomainController
            DomainControllerLookup  = ($nltestOutput -join "`n").Trim()
            PortResults             = $portResults.ToArray()
        }
    }

$data = $result.Data | Select-Object -First 1

return [pscustomobject]@{
    Passed                   = $true
    Check                    = 'Test-ActiveDirectoryReadiness'
    Node                     = $result.Node
    ManagementIp             = $result.ManagementIp
    IdentityMode             = 'ActiveDirectoryDomainServices'
    Domain                   = $data.Domain
    PartOfDomain             = $data.PartOfDomain
    ValidationDnsServer      = $data.DnsValidationServer
    DomainController         = $data.DomainController
    DomainControllerPorts    = $data.PortResults
    Summary                  = (
        "ADDS SRV resolution, domain controller lookup, and required " +
        "ports validated for $($data.DomainController)."
    )
    ValidatedAt              = [datetime]::UtcNow.ToString('o')
}