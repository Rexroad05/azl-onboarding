Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ManagementPlaneValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }

        return $null
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Get-ManagementPlaneSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $remoteManagement = Get-ManagementPlaneValue `
        -Object $Context.Config `
        -Name 'remote_management'

    if ($null -eq $remoteManagement) {
        throw 'remote_management configuration is required.'
    }

    $protocol = [string](
        Get-ManagementPlaneValue `
            -Object $remoteManagement `
            -Name 'protocol'
    )

    $port = Get-ManagementPlaneValue `
        -Object $remoteManagement `
        -Name 'port'

    $connectionTimeoutSeconds = Get-ManagementPlaneValue `
        -Object $remoteManagement `
        -Name 'connection_timeout_seconds'

    $operationTimeoutSeconds = Get-ManagementPlaneValue `
        -Object $remoteManagement `
        -Name 'operation_timeout_seconds'

    $domainCredentialUsernameEnvironmentVariable = [string](
        Get-ManagementPlaneValue `
            -Object $remoteManagement `
            -Name 'credential_username_env'
    )

    $domainCredentialPasswordEnvironmentVariable = [string](
        Get-ManagementPlaneValue `
            -Object $remoteManagement `
            -Name 'credential_password_env'
    )

    $localCredentialUsernameEnvironmentVariable = [string](
        Get-ManagementPlaneValue `
            -Object $remoteManagement `
            -Name 'local_credential_username_env'
    )

    $localCredentialPasswordEnvironmentVariable = [string](
        Get-ManagementPlaneValue `
            -Object $remoteManagement `
            -Name 'local_credential_password_env'
    )

    $bootstrapAuthenticationMode = [string](
        Get-ManagementPlaneValue `
            -Object $remoteManagement `
            -Name 'bootstrap_authentication_mode'
    )

    $bootstrapAuthenticationMethod = [string](
        Get-ManagementPlaneValue `
            -Object $remoteManagement `
            -Name 'bootstrap_authentication_method'
    )

    $certificateValidationMode = [string](
        Get-ManagementPlaneValue `
            -Object $remoteManagement `
            -Name 'certificate_validation_mode'
    )

    $allowTemporaryCertificateException = Get-ManagementPlaneValue `
        -Object $remoteManagement `
        -Name 'allow_temporary_certificate_exception'

    if ([string]::IsNullOrWhiteSpace($protocol)) {
        $protocol = 'WinRM-HTTPS'
    }

    if ($protocol -ne 'WinRM-HTTPS') {
        throw (
            "Unsupported remote-management protocol: $protocol. " +
            'Phase 1 bootstrap remoting requires WinRM-HTTPS.'
        )
    }

    if ($null -eq $port) {
        $port = 5986
    }

    if ($null -eq $connectionTimeoutSeconds) {
        $connectionTimeoutSeconds = 30
    }

    if ($null -eq $operationTimeoutSeconds) {
        $operationTimeoutSeconds = 60
    }

    if ([string]::IsNullOrWhiteSpace($bootstrapAuthenticationMode)) {
        $bootstrapAuthenticationMode = 'LocalAdministrator'
    }

    if ($bootstrapAuthenticationMode -ne 'LocalAdministrator') {
        throw (
            "Unsupported bootstrap_authentication_mode: " +
            "$bootstrapAuthenticationMode"
        )
    }

    if ([string]::IsNullOrWhiteSpace($bootstrapAuthenticationMethod)) {
        $bootstrapAuthenticationMethod = 'Negotiate'
    }

    if ($bootstrapAuthenticationMethod -ne 'Negotiate') {
        throw (
            "Unsupported bootstrap_authentication_method: " +
            "$bootstrapAuthenticationMethod. Negotiate is required."
        )
    }

    if ([string]::IsNullOrWhiteSpace(
            $domainCredentialUsernameEnvironmentVariable
        )) {
        throw 'remote_management.credential_username_env is required.'
    }

    if ([string]::IsNullOrWhiteSpace(
            $domainCredentialPasswordEnvironmentVariable
        )) {
        throw 'remote_management.credential_password_env is required.'
    }

    if ([string]::IsNullOrWhiteSpace(
            $localCredentialUsernameEnvironmentVariable
        )) {
        throw 'remote_management.local_credential_username_env is required.'
    }

    if ([string]::IsNullOrWhiteSpace(
            $localCredentialPasswordEnvironmentVariable
        )) {
        throw 'remote_management.local_credential_password_env is required.'
    }

    if ([string]::IsNullOrWhiteSpace($certificateValidationMode)) {
        $certificateValidationMode = 'Strict'
    }

    $runtimeCertificateMode = [Environment]::GetEnvironmentVariable(
        'FACTORY_WINRM_CERTIFICATE_MODE'
    )

    if (-not [string]::IsNullOrWhiteSpace($runtimeCertificateMode)) {
        $certificateValidationMode = $runtimeCertificateMode
    }

    if ($certificateValidationMode -notin @(
            'Strict',
            'ApprovedTemporaryException'
        )) {
        throw (
            "Unsupported WinRM certificate validation mode: " +
            "$certificateValidationMode"
        )
    }

    $port = [int]$port
    $connectionTimeoutSeconds = [int]$connectionTimeoutSeconds
    $operationTimeoutSeconds = [int]$operationTimeoutSeconds
    $allowTemporaryCertificateException = (
        $allowTemporaryCertificateException -eq $true
    )

    if ($port -lt 1 -or $port -gt 65535) {
        throw "Invalid WinRM port: $port"
    }

    if ($connectionTimeoutSeconds -lt 1) {
        throw (
            'remote_management.connection_timeout_seconds must be greater than zero.'
        )
    }

    if ($operationTimeoutSeconds -lt 1) {
        throw (
            'remote_management.operation_timeout_seconds must be greater than zero.'
        )
    }

    if (
        $certificateValidationMode -eq 'ApprovedTemporaryException' -and
        -not $allowTemporaryCertificateException
    ) {
        throw (
            'Temporary WinRM certificate exception is not authorized ' +
            'by protected package configuration.'
        )
    }

    return [pscustomobject]@{
        Protocol                                  = $protocol
        Port                                      = $port
        ConnectionTimeoutSecond                   = $connectionTimeoutSeconds
        OperationTimeoutSecond                    = $operationTimeoutSeconds
        UseSsl                                    = $true
        DomainCredentialUsernameEnvironmentVariable = $domainCredentialUsernameEnvironmentVariable
        DomainCredentialPasswordEnvironmentVariable = $domainCredentialPasswordEnvironmentVariable
        LocalCredentialUsernameEnvironmentVariable = $localCredentialUsernameEnvironmentVariable
        LocalCredentialPasswordEnvironmentVariable = $localCredentialPasswordEnvironmentVariable
        BootstrapAuthenticationMode               = $bootstrapAuthenticationMode
        BootstrapAuthenticationMethod             = $bootstrapAuthenticationMethod
        CertificateValidationMode                 = $certificateValidationMode
        AllowTemporaryCertificateException        = $allowTemporaryCertificateException
    }
}

function Get-ManagementPlaneTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    if (-not $Context.ContainsKey('Node')) {
        throw 'A node-scoped Context.Node is required.'
    }

    $node = $Context.Node

    $nodeName = [string](
        Get-ManagementPlaneValue `
            -Object $node `
            -Name 'name'
    )

    $management = Get-ManagementPlaneValue `
        -Object $node `
        -Name 'management'

    $managementIp = [string](
        Get-ManagementPlaneValue `
            -Object $management `
            -Name 'ip'
    )

    if ([string]::IsNullOrWhiteSpace($managementIp)) {
        $managementIp = [string](
            Get-ManagementPlaneValue `
                -Object $management `
                -Name 'ip_address'
        )
    }

    if ([string]::IsNullOrWhiteSpace($nodeName)) {
        throw 'Node context is missing node.name.'
    }

    if ([string]::IsNullOrWhiteSpace($managementIp)) {
        throw "Node $nodeName is missing management.ip or management.ip_address."
    }

    $settings = Get-ManagementPlaneSettings -Context $Context

    $bootstrapConnection = Get-ManagementPlaneValue `
        -Object $node `
        -Name 'bootstrap_connection'

    if ($null -ne $bootstrapConnection) {
        $connectionHost = [string](
            Get-ManagementPlaneValue `
                -Object $bootstrapConnection `
                -Name 'host'
        )

        $connectionPort = Get-ManagementPlaneValue `
            -Object $bootstrapConnection `
            -Name 'port'

        if ([string]::IsNullOrWhiteSpace($connectionHost)) {
            throw "Node $nodeName bootstrap_connection.host is required."
        }

        if ($null -eq $connectionPort) {
            $connectionPort = $settings.Port
        }

        $connectionPort = [int]$connectionPort

        if ($connectionPort -lt 1 -or $connectionPort -gt 65535) {
            throw (
                "Node $nodeName bootstrap_connection.port is invalid: " +
                "$connectionPort"
            )
        }

        try {
            $resolvedAddresses = @(
                [System.Net.Dns]::GetHostAddresses($connectionHost) |
                    Where-Object {
                        $_.AddressFamily -eq
                        [System.Net.Sockets.AddressFamily]::InterNetwork
                    } |
                    ForEach-Object {
                        $_.IPAddressToString
                    }
            )
        }
        catch {
            throw (
                "$nodeName | Bootstrap connection hostname resolution failed for " +
                "$connectionHost. $($_.Exception.Message)"
            )
        }

        if ($resolvedAddresses.Count -lt 1) {
            throw (
                "$nodeName | No IPv4 address was returned for bootstrap " +
                "connection host $connectionHost."
            )
        }

        return [pscustomobject]@{
            NodeName           = $nodeName
            ManagementIp       = $managementIp
            RemoteComputerName = $connectionHost
            ConnectionHost     = $connectionHost
            ConnectionPort     = $connectionPort
            ConnectionMode     = 'BootstrapExternalEndpoint'
            AuthenticationMode = 'LocalAdministrator'
            ResolvedAddresses  = $resolvedAddresses
        }
    }

    $naming = Get-ManagementPlaneValue `
        -Object $Context.Config `
        -Name 'naming'

    $domainFqdn = [string](
        Get-ManagementPlaneValue `
            -Object $naming `
            -Name 'domain_fqdn'
    )

    if ([string]::IsNullOrWhiteSpace($domainFqdn)) {
        $activeDirectory = Get-ManagementPlaneValue `
            -Object $Context.Config `
            -Name 'active_directory'

        $domainFqdn = [string](
            Get-ManagementPlaneValue `
                -Object $activeDirectory `
                -Name 'domain_fqdn'
        )
    }

    if ([string]::IsNullOrWhiteSpace($domainFqdn)) {
        throw (
            'naming.domain_fqdn or active_directory.domain_fqdn is required ' +
            'for internal FQDN WinRM authentication.'
        )
    }

    $remoteComputerName = "$nodeName.$domainFqdn"

    try {
        $resolvedAddresses = @(
            [System.Net.Dns]::GetHostAddresses($remoteComputerName) |
                Where-Object {
                    $_.AddressFamily -eq
                    [System.Net.Sockets.AddressFamily]::InterNetwork
                } |
                ForEach-Object {
                    $_.IPAddressToString
                }
        )
    }
    catch {
        throw (
            "$nodeName | DNS resolution failed for $remoteComputerName. " +
            "$($_.Exception.Message)"
        )
    }

    if ($resolvedAddresses.Count -lt 1) {
        throw (
            "$nodeName | No IPv4 DNS record was returned for " +
            "$remoteComputerName."
        )
    }

    if ($resolvedAddresses -notcontains $managementIp) {
        throw (
            "$nodeName | DNS record for $remoteComputerName does not include " +
            "the expected management IP $managementIp. " +
            "Resolved IPv4 values: $($resolvedAddresses -join ', ')"
        )
    }

    return [pscustomobject]@{
        NodeName           = $nodeName
        ManagementIp       = $managementIp
        RemoteComputerName = $remoteComputerName
        ConnectionHost     = $remoteComputerName
        ConnectionPort     = $settings.Port
        ConnectionMode     = 'InternalFqdn'
        AuthenticationMode = 'DomainAdds'
        ResolvedAddresses  = $resolvedAddresses
    }
}

function New-ManagementPlaneSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [pscredential]$Credential
    )

    $settings = Get-ManagementPlaneSettings -Context $Context
    $target = Get-ManagementPlaneTarget -Context $Context

    Write-Host (
        "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
        "$($target.NodeName) | Opening $($settings.Protocol) PSSession to " +
        "$($target.ConnectionHost):$($target.ConnectionPort) using " +
        "$($target.AuthenticationMode) authentication."
    ) -ForegroundColor DarkCyan

    if ($null -eq $Credential) {
        if ($target.AuthenticationMode -eq 'LocalAdministrator') {
            $username = [Environment]::GetEnvironmentVariable(
                $settings.LocalCredentialUsernameEnvironmentVariable
            )

            $password = [Environment]::GetEnvironmentVariable(
                $settings.LocalCredentialPasswordEnvironmentVariable
            )

            if ([string]::IsNullOrWhiteSpace($username)) {
                throw (
                    'Required local Administrator username environment variable is missing: ' +
                    $settings.LocalCredentialUsernameEnvironmentVariable
                )
            }

            if ([string]::IsNullOrWhiteSpace($password)) {
                throw (
                    'Required local Administrator password environment variable is missing: ' +
                    $settings.LocalCredentialPasswordEnvironmentVariable
                )
            }
        }
        else {
            $username = [Environment]::GetEnvironmentVariable(
                $settings.DomainCredentialUsernameEnvironmentVariable
            )

            $password = [Environment]::GetEnvironmentVariable(
                $settings.DomainCredentialPasswordEnvironmentVariable
            )

            if ([string]::IsNullOrWhiteSpace($username)) {
                throw (
                    'Required ADDS username environment variable is missing: ' +
                    $settings.DomainCredentialUsernameEnvironmentVariable
                )
            }

            if ([string]::IsNullOrWhiteSpace($password)) {
                throw (
                    'Required ADDS password environment variable is missing: ' +
                    $settings.DomainCredentialPasswordEnvironmentVariable
                )
            }
        }

        $Credential = [pscredential]::new(
            $username,
            (ConvertTo-SecureString $password -AsPlainText -Force)
        )
    }

    $sessionOptionParameters = @{
        OpenTimeout      = ($settings.ConnectionTimeoutSecond * 1000)
        OperationTimeout = ($settings.OperationTimeoutSecond * 1000)
    }

    if ($settings.CertificateValidationMode -eq 'ApprovedTemporaryException') {
        $temporaryApproval = [Environment]::GetEnvironmentVariable(
            'FACTORY_ALLOW_UNTRUSTED_WINRM'
        )

        if ($temporaryApproval -ne 'APPROVED_TEMPORARY_EXCEPTION') {
            throw (
                'Temporary WinRM certificate exception was requested but ' +
                'FACTORY_ALLOW_UNTRUSTED_WINRM approval is not present.'
            )
        }

        Write-Verbose (
            "$($target.NodeName) | TEMPORARY CERTIFICATE EXCEPTION ACTIVE. " +
            'CA trust and certificate revocation validation are skipped. ' +
            'Hostname/CN validation remains enforced.'
        )

        $sessionOptionParameters.SkipCACheck = $true
        $sessionOptionParameters.SkipRevocationCheck = $true
    }

    $sessionOption = New-PSSessionOption @sessionOptionParameters

    $authenticationMethod = if (
        $target.AuthenticationMode -eq 'LocalAdministrator'
    ) {
        $settings.BootstrapAuthenticationMethod
    }
    else {
        'Negotiate'
    }

    try {
        $session = New-PSSession `
            -ComputerName $target.ConnectionHost `
            -Port $target.ConnectionPort `
            -UseSSL `
            -Authentication $authenticationMethod `
            -Credential $Credential `
            -SessionOption $sessionOption `
            -ErrorAction Stop

        return [pscustomobject]@{
            Session = $session
            Settings = $settings
            Target = $target
        }
    }
    catch {
        throw (
            "$($target.NodeName) | Unable to open $($settings.Protocol) " +
            "PSSession to $($target.ConnectionHost):$($target.ConnectionPort). " +
            "$($_.Exception.Message)"
        )
    }
}

function Protect-ManagementPlaneErrorMessage {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Message,

        [AllowEmptyCollection()]
        [object[]]$SensitiveValues = @()
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return 'Remote management operation failed without a detailed error message.'
    }

    $sanitized = $Message

    foreach ($value in @($SensitiveValues)) {
        if (
            $value -is [string] -and
            -not [string]::IsNullOrWhiteSpace($value)
        ) {
            $sanitized = $sanitized.Replace(
                $value,
                '[REDACTED]'
            )
        }
    }

    $sanitized = $sanitized -replace `
        '(?i)bearer\s+[a-z0-9\-_\.=]+',
        'Bearer [REDACTED]'

    $sanitized = $sanitized -replace `
        '(?i)("ArmAccessToken"\s*:\s*")[^"]+',
        '$1[REDACTED]'

    $sanitized = $sanitized -replace `
        '(?i)(arm[_-]?access[_-]?token|token)\s*[:=]\s*\S+',
        '$1=[REDACTED]'

    return $sanitized
}
function Invoke-ManagementPlaneCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$OperationName,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList = @()
    )

    $testHooks = Get-ManagementPlaneValue `
        -Object $Context `
        -Name 'TestHooks'

    if ($null -ne $testHooks) {
        $remoteCommandInvoker = Get-ManagementPlaneValue `
            -Object $testHooks `
            -Name 'RemoteCommandInvoker'

        if ($remoteCommandInvoker -is [scriptblock]) {
            return & $remoteCommandInvoker `
                -Context $Context `
                -OperationName $OperationName `
                -ScriptBlock $ScriptBlock `
                -ArgumentList $ArgumentList
        }
    }

    $connection = $null

    try {
        $connection = New-ManagementPlaneSession -Context $Context

        Write-Host (
            "[$([datetime]::Now.ToString('HH:mm:ss'))] " +
            "$($connection.Target.NodeName) | Running $OperationName"
        ) -ForegroundColor DarkCyan

        $data = @(
            Invoke-Command `
                -Session $connection.Session `
                -ScriptBlock $ScriptBlock `
                -ArgumentList $ArgumentList `
                -ErrorAction Stop
        )

        return [pscustomobject]@{
            Node               = $connection.Target.NodeName
            ManagementIp       = $connection.Target.ManagementIp
            RemoteComputerName = $connection.Target.RemoteComputerName
            ConnectionHost     = $connection.Target.ConnectionHost
            ConnectionPort     = $connection.Target.ConnectionPort
            ConnectionMode     = $connection.Target.ConnectionMode
            AuthenticationMode = $connection.Target.AuthenticationMode
            Operation          = $OperationName
            Data               = $data
        }
    }
        catch {
        $sensitiveArgumentValues = @(
            $ArgumentList |
                Where-Object {
                    $_ -is [string] -and
                    $_.Length -gt 32
                }
        )

        $sanitizedError = Protect-ManagementPlaneErrorMessage `
            -Message $_.Exception.Message `
            -SensitiveValues $sensitiveArgumentValues

        throw "$OperationName failed. $sanitizedError"
    }
    finally {
        if (
            $null -ne $connection -and
            $null -ne $connection.Session
        ) {
            Remove-PSSession `
                -Session $connection.Session `
                -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function @(
    'Get-ManagementPlaneSettings',
    'Get-ManagementPlaneTarget',
    'Get-ManagementPlaneValue',
    'Invoke-ManagementPlaneCommand',
    'New-ManagementPlaneSession',
    'Protect-ManagementPlaneErrorMessage'
)