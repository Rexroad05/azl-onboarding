#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot\ManagementPlane.Common.psm1" -Force

$result = Invoke-ManagementPlaneCommand `
    -Context $Context `
    -OperationName 'Test-AzureLocalOfficialHardwareValidation' `
    -ScriptBlock {
        function Get-ObjectPropertyValue {
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
                if (@($Object.Keys) -contains $Name) {
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

        function Get-ValidationFailureRecords {
            param(
                [Parameter(Mandatory)]
                [object[]]$InputObject
            )

            $findings = [System.Collections.Generic.List[object]]::new()
            $seenFindingKeys = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )

            function Visit-ValidationObject {
                param(
                    [AllowNull()]
                    [object]$Object,

                    [int]$Depth = 0
                )

                if ($null -eq $Object -or $Depth -gt 12) {
                    return
                }

                if (
                    $Object -is [string] -or
                    $Object -is [ValueType]
                ) {
                    return
                }

                $severity = [string](
                    Get-ObjectPropertyValue `
                        -Object $Object `
                        -Name 'Severity'
                )

                $status = [string](
                    Get-ObjectPropertyValue `
                        -Object $Object `
                        -Name 'Status'
                )

                $healthState = [string](
                    Get-ObjectPropertyValue `
                        -Object $Object `
                        -Name 'HealthState'
                )

                if ([string]::IsNullOrWhiteSpace($healthState)) {
                    $healthState = [string](
                        Get-ObjectPropertyValue `
                            -Object $Object `
                            -Name 'Health'
                    )
                }

                $outcome = [string](
                    Get-ObjectPropertyValue `
                        -Object $Object `
                        -Name 'Outcome'
                )

                $resultValue = [string](
                    Get-ObjectPropertyValue `
                        -Object $Object `
                        -Name 'Result'
                )

                # Microsoft validation Severity identifies the importance of a check;
                # it does not identify the check outcome. For example, a check can be
                # Severity=CRITICAL and Status=SUCCESS. Only outcome/status fields may
                # cause this read-only adapter to report a finding.
                $failureSignal = @(
                    $status,
                    $healthState,
                    $severity,
                    $outcome,
                    $resultValue
                ) -join ' '

                if (
                    $failureSignal -match
                    '(?i)\b(error|failed|failure|unhealthy|needs\s*remediation)\b'
                ) {
                    $checkName = [string](
                        Get-ObjectPropertyValue `
                            -Object $Object `
                            -Name 'Name'
                    )

                    if ([string]::IsNullOrWhiteSpace($checkName)) {
                        $checkName = [string](
                            Get-ObjectPropertyValue `
                                -Object $Object `
                                -Name 'CheckName'
                        )
                    }

                    if ([string]::IsNullOrWhiteSpace($checkName)) {
                        $checkName = [string](
                            Get-ObjectPropertyValue `
                                -Object $Object `
                                -Name 'DisplayName'
                        )
                    }

                    if ([string]::IsNullOrWhiteSpace($checkName)) {
                        $checkName = [string](
                            Get-ObjectPropertyValue `
                                -Object $Object `
                                -Name 'RuleName'
                        )
                    }

                    if ([string]::IsNullOrWhiteSpace($checkName)) {
                        $checkName = 'Unnamed official hardware validation check'
                    }

                    $message = [string](
                        Get-ObjectPropertyValue `
                            -Object $Object `
                            -Name 'Message'
                    )

                    if ([string]::IsNullOrWhiteSpace($message)) {
                        $message = [string](
                            Get-ObjectPropertyValue `
                                -Object $Object `
                                -Name 'Description'
                        )
                    }

                    $findingKey = (
                        '{0}|{1}|{2}|{3}|{4}' -f
                        $checkName,
                        $severity,
                        $status,
                        $healthState,
                        $outcome
                    )

                    if ($seenFindingKeys.Add($findingKey)) {
                        $findings.Add(
                            [pscustomobject]@{
                                CheckName   = $checkName
                                Severity    = $severity
                                Status      = $status
                                HealthState = $healthState
                                Outcome     = $outcome
                                Message     = $message
                            }
                        )
                    }
                }

                if ($Object -is [System.Collections.IDictionary]) {
                    foreach ($value in $Object.Values) {
                        if (
                            $value -isnot [string] -and
                            $value -isnot [ValueType]
                        ) {
                            Visit-ValidationObject `
                                -Object $value `
                                -Depth ($Depth + 1)
                        }
                    }

                    return
                }

                foreach ($property in $Object.PSObject.Properties) {
                    $propertyValue = $property.Value

                    if ($null -eq $propertyValue) {
                        continue
                    }

                    if (
                        $propertyValue -is [string] -or
                        $propertyValue -is [ValueType]
                    ) {
                        continue
                    }

                    if (
                        $propertyValue -is [System.Collections.IEnumerable]
                    ) {
                        foreach ($item in @($propertyValue)) {
                            Visit-ValidationObject `
                                -Object $item `
                                -Depth ($Depth + 1)
                        }

                        continue
                    }

                    Visit-ValidationObject `
                        -Object $propertyValue `
                        -Depth ($Depth + 1)
                }
            }

            foreach ($resultItem in $InputObject) {
                Visit-ValidationObject -Object $resultItem
            }

            return $findings.ToArray()
        }

        $command = Get-Command `
            -Name Invoke-AzStackHciHardwareValidation `
            -ErrorAction SilentlyContinue

        if ($null -eq $command) {
            throw 'Invoke-AzStackHciHardwareValidation is unavailable.'
        }

        if (@($command.Parameters.Keys) -notcontains 'PassThru') {
            throw (
                'Invoke-AzStackHciHardwareValidation does not expose the ' +
                'required -PassThru parameter. The factory will not treat ' +
                'console-only validation output as a passing result.'
            )
        }

        $validationResults = @(
            Invoke-AzStackHciHardwareValidation `
                -PassThru `
                -ErrorAction Stop
        )

        if ($validationResults.Count -lt 1) {
            throw (
                'Invoke-AzStackHciHardwareValidation returned no structured ' +
                'results through -PassThru. The factory will not report this ' +
                'validation as passed.'
            )
        }

        $failureRecords = @(
            Get-ValidationFailureRecords `
                -InputObject $validationResults
        )

        if ($failureRecords.Count -gt 0) {
            $failureSummary = @(
                $failureRecords |
                    ForEach-Object {
                        $checkName = $_.CheckName

                        $state = @(
                            $_.Severity,
                            $_.Status,
                            $_.HealthState,
                            $_.Outcome
                        ) |
                            Where-Object {
                                -not [string]::IsNullOrWhiteSpace(
                                    [string]$_
                                )
                            } |
                            Select-Object -Unique

                        $message = [string]$_.Message

                        if ([string]::IsNullOrWhiteSpace($message)) {
                            "$checkName [$($state -join '; ')]"
                        }
                        else {
                            "$checkName [$($state -join '; ')] $message"
                        }
                    }
            ) -join ' | '

            throw (
                'Azure Local official hardware validation reported critical ' +
                "or failed readiness conditions: $failureSummary"
            )
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            ResultCount  = $validationResults.Count
            ResultType   = (
                $validationResults[0].PSObject.TypeNames |
                    Select-Object -First 1
            )
        }
    }

$data = @(
    $result.Data |
        Select-Object -First 1
)

if ($data.Count -ne 1 -or $null -eq $data[0]) {
    throw (
        'Official Azure Local hardware validation completed without a ' +
        'usable structured result.'
    )
}

return [pscustomobject]@{
    Passed       = $true
    Check        = 'Test-AzureLocalOfficialHardwareValidation'
    Node         = $result.Node
    ManagementIp = $result.ManagementIp
    ResultCount  = $data[0].ResultCount
    ResultType   = $data[0].ResultType
    Summary      = (
        'Official Azure Local hardware validation completed with structured ' +
        'PassThru output and no critical or failed readiness conditions.'
    )
    ValidatedAt  = [datetime]::UtcNow.ToString('o')
}