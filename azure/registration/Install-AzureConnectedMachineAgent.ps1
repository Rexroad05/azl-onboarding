#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module powershell-yaml -ErrorAction Stop
Import-Module "$PSScriptRoot\..\..\bootstrap\os\HcnEnsure.Common.psm1" -Force
Import-Module "$PSScriptRoot\..\..\preflight\ManagementPlane.Common.psm1" -Force

function Get-ArcValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    return Get-HcnEnsureValue `
        -Object $Object `
        -Name $Name
}

function Get-ApprovalKey {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$NodeName
    )

    $phaseId = Get-ArcValue `
        -Object $Context `
        -Name 'PhaseId'

    $stageId = Get-ArcValue `
        -Object $Context `
        -Name 'StageId'

    $operation = [string](
        Get-ArcValue `
            -Object $Context `
            -Name 'Operation'
    )

    if ($null -eq $phaseId) {
        $phaseId = 1
    }

    if ($null -eq $stageId) {
        $stageId = 4
    }

    if ([string]::IsNullOrWhiteSpace($operation)) {
        $operation = 'Install-AzureConnectedMachineAgent'
    }

    return (
        "$phaseId." +
        "$stageId." +
        "$NodeName." +
        "$operation"
    )
}

function Test-ApprovedOperation {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Context,

        [Parameter(Mandatory)]
        [string]$ApprovalKey
    )

    $state = Get-ArcValue `
        -Object $Context `
        -Name 'State'

    $approvedOperations = Get-ArcValue `
        -Object $state `
        -Name 'approvedOperations'

    if ($null -eq $approvedOperations) {
        return $false
    }

    if ($approvedOperations -is [System.Collections.IDictionary]) {
        return (@($approvedOperations.Keys) -contains $ApprovalKey)
    }

    return (
        $null -ne $approvedOperations.PSObject.Properties[$ApprovalKey]
    )
}

function Get-MsiProductVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer

        $database = $installer.OpenDatabase(
            $Path,
            0
        )

        $view = $database.OpenView(
            "SELECT `Value` FROM `Property` WHERE `Property` = 'ProductVersion'"
        )

        $view.Execute()

        $record = $view.Fetch()

        if ($null -eq $record) {
            return $null
        }

        return [string]$record.StringData(1)
    }
    catch {
        return $null
    }
}

function Resolve-LocalArcAgentPath {
    param(
        [AllowNull()]
        [string]$ExpectedPath
    )

    $candidatePaths = @(
        $ExpectedPath
        "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"
        "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
    ) |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } |
        Select-Object -Unique

    foreach ($candidatePath in $candidatePaths) {
        if (
            Test-Path `
                -LiteralPath $candidatePath `
                -PathType Leaf
        ) {
            return $candidatePath
        }
    }

    $agent = Get-Command `
        -Name 'azcmagent.exe', 'azcmagent' `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($null -ne $agent) {
        return [string]$agent.Source
    }

    return $null
}

$node = Get-ArcValue `
    -Object $Context `
    -Name 'Node'

if ($null -eq $node) {
    throw 'Install-AzureConnectedMachineAgent requires a node-scoped context.'
}

$config = Get-ArcValue `
    -Object $Context `
    -Name 'Config'

$azure = Get-ArcValue `
    -Object $config `
    -Name 'azure'

$arcAgent = Get-ArcValue `
    -Object $azure `
    -Name 'arc_agent'

if ($null -eq $arcAgent) {
    throw 'azure.arc_agent configuration is required.'
}

$required = (
    Get-ArcValue `
        -Object $arcAgent `
        -Name 'required'
) -eq $true

$installationMode = [string](
    Get-ArcValue `
        -Object $arcAgent `
        -Name 'installation_mode'
)

$expectedAgentPath = [string](
    Get-ArcValue `
        -Object $arcAgent `
        -Name 'agent_executable_path'
)

$himdsServiceName = [string](
    Get-ArcValue `
        -Object $arcAgent `
        -Name 'himds_service_name'
)

if ([string]::IsNullOrWhiteSpace($himdsServiceName)) {
    $himdsServiceName = 'himds'
}

if (-not $required) {
    return New-HcnEnsureResult `
        -Check 'Install-AzureConnectedMachineAgent' `
        -Outcome 'AlreadyCompliant' `
        -Summary (
            'Azure Connected Machine agent installation is not required by ' +
            'the resolved profile.'
        ) `
        -AdditionalProperties @{
            Node = [string]$node.name
            Required = $false
        }
}

if ($installationMode -ne 'FactoryManaged') {
    return New-HcnEnsureResult `
        -Check 'Install-AzureConnectedMachineAgent' `
        -Outcome 'AlreadyCompliant' `
        -Summary (
            "Azure Connected Machine agent installation mode is " +
            "$installationMode. Factory installation is not selected."
        ) `
        -AdditionalProperties @{
            Node = [string]$node.name
            InstallationMode = $installationMode
        }
}

$manifestPath = Join-Path `
    $Context.Root `
    'protected\arc-agent-manifest.yaml'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Arc agent manifest does not exist: $manifestPath"
}

$manifest = Get-Content `
    -LiteralPath $manifestPath `
    -Raw |
    ConvertFrom-Yaml `
    -Ordered

$arcAgentManifest = $manifest.arc_agent

if ($null -eq $arcAgentManifest) {
    throw 'arc-agent-manifest.yaml does not contain arc_agent configuration.'
}

$installer = $arcAgentManifest.installer
$behavior = $arcAgentManifest.behavior

$sourceType = [string]$installer.source_type
$executionHostPath = [string]$installer.execution_host_path
$fileName = [string]$installer.file_name
$expectedSha256 = [string]$installer.expected_sha256
$requireValidSignature = [bool]$installer.require_valid_authenticode_signature
$expectedSignerSubject = [string]$installer.expected_signer_subject
$expectedSignerIssuer = [string]$installer.expected_signer_issuer
$expectedSignerThumbprint = [string]$installer.expected_signer_thumbprint
$expectedProductVersion = [string]$installer.expected_product_version
$nodeStagingDirectory = [string]$installer.node_staging_directory
$installLogDirectory = [string]$installer.install_log_directory
$installArguments = @($installer.install_arguments)
$acceptedExitCodes = @($installer.accepted_exit_codes)

$requireExplicitApproval = [bool]$behavior.require_explicit_approval
$allowAutomaticUpgrade = [bool]$behavior.allow_automatic_upgrade
$allowReinstallWhenPresent = [bool]$behavior.allow_reinstall_when_agent_present
$requireHimdsRunning = [bool]$behavior.require_post_install_himds_running
$requireAzcmagent = [bool]$behavior.require_post_install_azcmagent
$prohibitConnect = [bool]$behavior.prohibit_azcmagent_connect_during_install
$prohibitExtensionInstall = [bool]$behavior.prohibit_extension_install_during_install

if ($sourceType -ne 'ExecutionHostStagedMsi') {
    throw (
        "Unsupported arc agent installer source type: $sourceType. " +
        'ExecutionHostStagedMsi is required.'
    )
}

foreach ($requiredValue in @(
        @{
            Name = 'execution_host_path'
            Value = $executionHostPath
        },
        @{
            Name = 'file_name'
            Value = $fileName
        },
        @{
            Name = 'expected_sha256'
            Value = $expectedSha256
        },
        @{
            Name = 'expected_signer_subject'
            Value = $expectedSignerSubject
        },
        @{
            Name = 'node_staging_directory'
            Value = $nodeStagingDirectory
        },
        @{
            Name = 'install_log_directory'
            Value = $installLogDirectory
        }
    )) {
    if ([string]::IsNullOrWhiteSpace([string]$requiredValue.Value)) {
        throw (
            "arc_agent.installer.$($requiredValue.Name) is required."
        )
    }
}

if (-not (Test-Path -LiteralPath $executionHostPath -PathType Leaf)) {
    throw (
        "Approved Arc agent installer does not exist on execution workstation: " +
        $executionHostPath
    )
}

if ([IO.Path]::GetFileName($executionHostPath) -ne $fileName) {
    throw (
        "Arc agent installer filename mismatch. Expected $fileName; found " +
        "$([IO.Path]::GetFileName($executionHostPath))."
    )
}

$executionHash = (
    Get-FileHash `
        -LiteralPath $executionHostPath `
        -Algorithm SHA256
).Hash

if ($executionHash -ine $expectedSha256) {
    throw (
        "Arc agent execution-workstation hash mismatch. Expected " +
        "$expectedSha256; found $executionHash."
    )
}

$executionSignature = Get-AuthenticodeSignature `
    -FilePath $executionHostPath

if ($requireValidSignature -and $executionSignature.Status -ne 'Valid') {
    throw (
        "Arc agent execution-workstation signature is not valid. " +
        "Status: $($executionSignature.Status)."
    )
}

if (
    -not [string]::IsNullOrWhiteSpace($expectedSignerSubject) -and
    $executionSignature.SignerCertificate.Subject -ne $expectedSignerSubject
) {
    throw (
        'Arc agent execution-workstation signer subject does not match ' +
        'protected manifest.'
    )
}

if (
    -not [string]::IsNullOrWhiteSpace($expectedSignerIssuer) -and
    $executionSignature.SignerCertificate.Issuer -ne $expectedSignerIssuer
) {
    throw (
        'Arc agent execution-workstation signer issuer does not match ' +
        'protected manifest.'
    )
}

if (
    -not [string]::IsNullOrWhiteSpace($expectedSignerThumbprint) -and
    $executionSignature.SignerCertificate.Thumbprint -ne $expectedSignerThumbprint
) {
    throw (
        'Arc agent execution-workstation signer thumbprint does not match ' +
        'protected manifest.'
    )
}

$executionMsiVersion = Get-MsiProductVersion `
    -Path $executionHostPath

if (
    -not [string]::IsNullOrWhiteSpace($expectedProductVersion) -and
    $executionMsiVersion -ne $expectedProductVersion
) {
    throw (
        "Arc agent MSI version mismatch. Expected $expectedProductVersion; " +
        "found $executionMsiVersion."
    )
}

$nodeName = [string]$node.name
$approvalKey = Get-ApprovalKey `
    -Context $Context `
    -NodeName $nodeName

$inspectionResponse = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Install-AzureConnectedMachineAgent' `
    -ArgumentList @(
        $expectedAgentPath,
        $himdsServiceName
    ) `
    -ScriptBlock {
        param(
            [string]$ExpectedAgentPath,
            [string]$HimdsServiceName
        )

        function Resolve-AzureConnectedMachineAgentPath {
            param(
                [AllowNull()]
                [string]$ExpectedPath
            )

            $candidatePaths = @(
                $ExpectedPath
                "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"
                "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
            ) |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                } |
                Select-Object -Unique

            foreach ($candidatePath in $candidatePaths) {
                if (
                    Test-Path `
                        -LiteralPath $candidatePath `
                        -PathType Leaf
                ) {
                    return $candidatePath
                }
            }

            $agent = Get-Command `
                -Name 'azcmagent.exe', 'azcmagent' `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($null -ne $agent) {
                return [string]$agent.Source
            }

            return $null
        }

        $agentPath = Resolve-AzureConnectedMachineAgentPath `
            -ExpectedPath $ExpectedAgentPath

        $himds = Get-Service `
            -Name $HimdsServiceName `
            -ErrorAction SilentlyContinue

        [pscustomobject]@{
            AgentPresent = -not [string]::IsNullOrWhiteSpace($agentPath)
            AgentPath    = $agentPath
            AgentVersion = if (
                -not [string]::IsNullOrWhiteSpace($agentPath)
            ) {
                @(
                    & $agentPath --version 2>&1
                ) -join "`n"
            }
            else {
                $null
            }
            HimdsPresent = ($null -ne $himds)
            HimdsStatus  = if ($null -ne $himds) {
                [string]$himds.Status
            }
            else {
                $null
            }
        }
    }

$inspection = @($inspectionResponse.Data) |
    Select-Object -First 1

if ($inspection.AgentPresent) {
    if (-not $allowReinstallWhenPresent) {
        if (
            $requireHimdsRunning -and
            (
                -not $inspection.HimdsPresent -or
                $inspection.HimdsStatus -ne 'Running'
            )
        ) {
            return New-HcnEnsureResult `
                -Check 'Install-AzureConnectedMachineAgent' `
                -Outcome 'Blocked' `
                -Summary (
                    "Azure Connected Machine agent exists on node $nodeName, " +
                    'but HIMDS is not present or not running.'
                ) `
                -AdditionalProperties @{
                    Node         = $nodeName
                    AgentPresent = $inspection.AgentPresent
                    AgentPath    = $inspection.AgentPath
                    AgentVersion = $inspection.AgentVersion
                    HimdsPresent = $inspection.HimdsPresent
                    HimdsStatus  = $inspection.HimdsStatus
                }
        }

        return New-HcnEnsureResult `
            -Check 'Install-AzureConnectedMachineAgent' `
            -Outcome 'AlreadyCompliant' `
            -Summary (
                "Azure Connected Machine agent is already present on node " +
                "$nodeName. Reinstallation is disabled by protected policy."
            ) `
            -AdditionalProperties @{
                Node         = $nodeName
                AgentPresent = $inspection.AgentPresent
                AgentPath    = $inspection.AgentPath
                AgentVersion = $inspection.AgentVersion
                HimdsPresent = $inspection.HimdsPresent
                HimdsStatus  = $inspection.HimdsStatus
            }
    }

    return New-HcnEnsureResult `
        -Check 'Install-AzureConnectedMachineAgent' `
        -Outcome 'Blocked' `
        -Summary (
            "Azure Connected Machine agent is already present on node $nodeName " +
            'and protected policy requires a separate upgrade decision.'
        ) `
        -AdditionalProperties @{
            Node         = $nodeName
            AgentPresent = $inspection.AgentPresent
            AgentPath    = $inspection.AgentPath
            AgentVersion = $inspection.AgentVersion
            HimdsPresent = $inspection.HimdsPresent
            HimdsStatus  = $inspection.HimdsStatus
        }
}

if (
    $requireExplicitApproval -and
    -not (Test-ApprovedOperation -Context $Context -ApprovalKey $approvalKey)
) {
    return New-HcnEnsureResult `
        -Check 'Install-AzureConnectedMachineAgent' `
        -Outcome 'Blocked' `
        -Summary (
            "Azure Connected Machine agent installation is required for node " +
            "$nodeName. Explicit approval is required before installation."
        ) `
        -AdditionalProperties @{
            RequiresApproval = $true
            ApprovalReason   = (
                'The factory will transfer a verified Microsoft-signed MSI to ' +
                'the node and install the Azure Connected Machine agent. Arc ' +
                'registration and extension installation are explicitly excluded ' +
                'from this action.'
            )
            RequiresReboot   = $false
            ReconnectTarget  = $nodeName
            Node             = $nodeName
            InstallerSha256  = $expectedSha256
            InstallerSigner  = $expectedSignerSubject
            InstallerPath    = $executionHostPath
        }
}

$connection = $null

try {
    $connection = New-ManagementPlaneSession `
        -Context $Context

    $remoteInstallerPath = Join-Path `
        $nodeStagingDirectory `
        $fileName

    $remoteInstallLogPath = Join-Path `
        $installLogDirectory `
        'AzureConnectedMachineAgent-install.log'

    Invoke-Command `
        -Session $connection.Session `
        -ArgumentList @(
            $nodeStagingDirectory,
            $installLogDirectory
        ) `
        -ErrorAction Stop `
        -ScriptBlock {
            param(
                [string]$NodeStagingDirectory,
                [string]$InstallLogDirectory
            )

            New-Item `
                -ItemType Directory `
                -Path $NodeStagingDirectory `
                -Force |
                Out-Null

            New-Item `
                -ItemType Directory `
                -Path $InstallLogDirectory `
                -Force |
                Out-Null
        }

    Copy-Item `
        -LiteralPath $executionHostPath `
        -Destination $remoteInstallerPath `
        -ToSession $connection.Session `
        -Force

    $installResponse = Invoke-Command `
        -Session $connection.Session `
        -ArgumentList @(
            $remoteInstallerPath,
            $remoteInstallLogPath,
            $expectedSha256,
            $requireValidSignature,
            $expectedSignerSubject,
            $expectedSignerIssuer,
            $expectedSignerThumbprint,
            $installArguments,
            $acceptedExitCodes,
            $nodeStagingDirectory,
            $installLogDirectory,
            $requireHimdsRunning,
            $requireAzcmagent,
            $prohibitConnect,
            $prohibitExtensionInstall,
            $expectedAgentPath,
            $himdsServiceName
        ) `
        -ErrorAction Stop `
        -ScriptBlock {
            param(
                [string]$InstallerPath,
                [string]$InstallLogPath,
                [string]$ExpectedSha256,
                [bool]$RequireValidSignature,
                [string]$ExpectedSignerSubject,
                [string]$ExpectedSignerIssuer,
                [string]$ExpectedSignerThumbprint,
                [string[]]$InstallArguments,
                [int[]]$AcceptedExitCodes,
                [string]$NodeStagingDirectory,
                [string]$InstallLogDirectory,
                [bool]$RequireHimdsRunning,
                [bool]$RequireAzcmagent,
                [bool]$ProhibitConnect,
                [bool]$ProhibitExtensionInstall,
                [string]$ExpectedAgentPath,
                [string]$HimdsServiceName
            )

            function Resolve-AzureConnectedMachineAgentPath {
                param(
                    [AllowNull()]
                    [string]$ExpectedPath
                )

                $candidatePaths = @(
                    $ExpectedPath
                    "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"
                    "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe"
                ) |
                    Where-Object {
                        -not [string]::IsNullOrWhiteSpace($_)
                    } |
                    Select-Object -Unique

                foreach ($candidatePath in $candidatePaths) {
                    if (
                        Test-Path `
                            -LiteralPath $candidatePath `
                            -PathType Leaf
                    ) {
                        return $candidatePath
                    }
                }

                $agent = Get-Command `
                    -Name 'azcmagent.exe', 'azcmagent' `
                    -ErrorAction SilentlyContinue |
                    Select-Object -First 1

                if ($null -ne $agent) {
                    return [string]$agent.Source
                }

                return $null
            }

            New-Item `
                -ItemType Directory `
                -Path $NodeStagingDirectory `
                -Force |
                Out-Null

            New-Item `
                -ItemType Directory `
                -Path $InstallLogDirectory `
                -Force |
                Out-Null

            if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
                throw "Transferred Arc agent MSI was not found: $InstallerPath"
            }

            $remoteHash = (
                Get-FileHash `
                    -LiteralPath $InstallerPath `
                    -Algorithm SHA256
            ).Hash

            if ($remoteHash -ine $ExpectedSha256) {
                throw (
                    "Transferred Arc agent MSI hash mismatch. Expected " +
                    "$ExpectedSha256; found $remoteHash."
                )
            }

            $signature = Get-AuthenticodeSignature `
                -FilePath $InstallerPath

            if ($RequireValidSignature -and $signature.Status -ne 'Valid') {
                throw (
                    "Transferred Arc agent MSI signature is not valid. " +
                    "Status: $($signature.Status)."
                )
            }

            if (
                -not [string]::IsNullOrWhiteSpace($ExpectedSignerSubject) -and
                $signature.SignerCertificate.Subject -ne $ExpectedSignerSubject
            ) {
                throw (
                    'Transferred Arc agent MSI signer subject does not match ' +
                    'protected manifest.'
                )
            }

            if (
                -not [string]::IsNullOrWhiteSpace($ExpectedSignerIssuer) -and
                $signature.SignerCertificate.Issuer -ne $ExpectedSignerIssuer
            ) {
                throw (
                    'Transferred Arc agent MSI signer issuer does not match ' +
                    'protected manifest.'
                )
            }

            if (
                -not [string]::IsNullOrWhiteSpace($ExpectedSignerThumbprint) -and
                $signature.SignerCertificate.Thumbprint -ne $ExpectedSignerThumbprint
            ) {
                throw (
                    'Transferred Arc agent MSI signer thumbprint does not match ' +
                    'protected manifest.'
                )
            }

            $resolvedArguments = @(
                $InstallArguments |
                    ForEach-Object {
                        $_.
                            Replace('{InstallerPath}', $InstallerPath).
                            Replace('{InstallLogPath}', $InstallLogPath)
                    }
            )

            $process = Start-Process `
                -FilePath 'msiexec.exe' `
                -ArgumentList $resolvedArguments `
                -Wait `
                -PassThru `
                -ErrorAction Stop

            $exitCode = [int]$process.ExitCode

            if ($AcceptedExitCodes -notcontains $exitCode) {
                throw (
                    "Azure Connected Machine agent MSI installation failed with " +
                    "exit code $exitCode. Review $InstallLogPath."
                )
            }

            $agentPath = Resolve-AzureConnectedMachineAgentPath `
                -ExpectedPath $ExpectedAgentPath

            $himds = Get-Service `
                -Name $HimdsServiceName `
                -ErrorAction SilentlyContinue

            if ($RequireAzcmagent -and [string]::IsNullOrWhiteSpace($agentPath)) {
                throw (
                    'Azure Connected Machine agent executable was not found ' +
                    'after installation.'
                )
            }

            if (
                $RequireHimdsRunning -and
                (
                    $null -eq $himds -or
                    $himds.Status -ne 'Running'
                )
            ) {
                throw (
                    "HIMDS service $HimdsServiceName is not present or running " +
                    'after agent installation.'
                )
            }

                        $agentStatus = $null
            $agentResourceId = $null
            $agentResourceGroup = $null
            $agentSubscriptionId = $null

            if ($ProhibitConnect) {
                $agentShowJson = @(
                    & $agentPath show -j 2>&1
                ) -join "`n"

                try {
                    $agentShow = $agentShowJson |
                        ConvertFrom-Json `
                            -ErrorAction Stop
                }
                catch {
                    throw (
                        'Azure Connected Machine agent status could not be parsed ' +
                        "after installation. $($_.Exception.Message)"
                    )
                }

                $agentStatus = [string]$agentShow.status
                $agentResourceId = [string]$agentShow.resourceId
                $agentResourceGroup = [string]$agentShow.resourceGroup
                $agentSubscriptionId = [string]$agentShow.subscriptionId

                $agentConnected = (
                    $agentStatus -eq 'Connected' -and
                    -not [string]::IsNullOrWhiteSpace($agentResourceId)
                )

                if ($agentConnected) {
                    throw (
                        'Arc agent is connected after installation. Registration ' +
                        'is prohibited during installer execution.'
                    )
                }
            }

            [pscustomobject]@{
                InstallerPath          = $InstallerPath
                InstallLogPath         = $InstallLogPath
                ExitCode               = $exitCode
                RequiresReboot         = ($exitCode -eq 3010)
                AgentPresent           = -not [string]::IsNullOrWhiteSpace($agentPath)
                AgentPath              = $agentPath
                AgentVersion           = if (
                    -not [string]::IsNullOrWhiteSpace($agentPath)
                ) {
                    @(
                        & $agentPath --version 2>&1
                    ) -join "`n"
                }
                else {
                    $null
                }
                HimdsPresent           = ($null -ne $himds)
                HimdsStatus            = if ($null -ne $himds) {
                    [string]$himds.Status
                }
                else {
                    $null
                }
                                AgentStatus            = $agentStatus
                AgentResourceId        = $agentResourceId
                AgentResourceGroup     = $agentResourceGroup
                AgentSubscriptionId    = $agentSubscriptionId
                ProhibitExtensionInstall = $ProhibitExtensionInstall
            }
        }

    $installResult = @($installResponse) |
        Select-Object -First 1

    if ($installResult.RequiresReboot) {
        return New-HcnEnsureResult `
            -Check 'Install-AzureConnectedMachineAgent' `
            -Outcome 'Changed' `
            -Changed $true `
            -Summary (
                "Azure Connected Machine agent installed on node $nodeName. " +
                'Installer exit code 3010 requires reboot approval and post-reboot validation.'
            ) `
            -AdditionalProperties @{
                Node             = $nodeName
                InstallerSha256  = $expectedSha256
                InstallLogPath   = $installResult.InstallLogPath
                AgentPath        = $installResult.AgentPath
                AgentVersion     = $installResult.AgentVersion
                HimdsStatus      = $installResult.HimdsStatus
                RequiresReboot   = $true
                ReconnectTarget  = $nodeName
                PauseRequested   = $true
                PauseType        = 'Reboot'
                RebootReason     = (
                    'Azure Connected Machine agent installation returned MSI ' +
                    'exit code 3010. A reboot and post-reboot validation are required.'
                )
            }
    }

    return New-HcnEnsureResult `
        -Check 'Install-AzureConnectedMachineAgent' `
        -Outcome 'Changed' `
        -Changed $true `
        -Summary (
            "Azure Connected Machine agent installed and validated on node " +
            "$nodeName. Arc registration was not performed."
        ) `
        -AdditionalProperties @{
            Node                     = $nodeName
            InstallerSha256          = $expectedSha256
            InstallLogPath           = $installResult.InstallLogPath
            AgentPath                = $installResult.AgentPath
            AgentVersion             = $installResult.AgentVersion
            HimdsPresent             = $installResult.HimdsPresent
            HimdsStatus              = $installResult.HimdsStatus
            ArcRegistrationExcluded  = $true
            ExtensionInstallExcluded = $true
        }
}
finally {
    if ($null -ne $connection -and $null -ne $connection.Session) {
        Remove-PSSession `
            -Session $connection.Session `
            -ErrorAction SilentlyContinue
    }
}