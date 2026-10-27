#Requires -Version 7.4

. "$PSScriptRoot\TestHelpers.ps1"

$reportScriptPath = Get-TestRepositoryPath `
    -RelativePath 'reports\New-ValidationFindingsReport.ps1'

Describe 'Validation Findings Report' {
    It 'parses the validation findings report generator' {
        @(Get-TestParseErrors `
            -RelativePath 'reports\New-ValidationFindingsReport.ps1').Count |
            Should Be 0
    }

    It 'creates HTML and JSON validation findings artifacts' {
        $temporaryRunDirectory = Join-Path `
            $env:TEMP `
            ("validation-findings-test-" + [guid]::NewGuid().ToString('N'))

        try {
            New-Item `
                -ItemType Directory `
                -Force `
                -Path $temporaryRunDirectory |
                Out-Null

            $results = @(
                [pscustomobject]@{
                    Operation = 'Test-NICState'
                    Node = 'TESTHCN01'
                    Status = 'Passed'
                    Classification = 'Compliant'
                    Summary = 'Four adapters detected.'
                    Details = [pscustomobject]@{
                        Adapters = @(
                            [pscustomobject]@{
                                Name = 'Management1'
                                Status = 'Up'
                            }
                        )
                    }
                },
                [pscustomobject]@{
                    Operation = 'Test-RdmaState'
                    Node = 'TESTHCN01'
                    Status = 'Finding'
                    Classification = 'ReferenceDifference'
                    Summary = 'RDMA is not operational on Storage1.'
                    Details = $null
                }
            )

            $report = & $reportScriptPath `
                -RunDirectory $temporaryRunDirectory `
                -Site 'TEST' `
                -ProfileName 'HcnDiscoveryReadiness' `
                -DisplayName '1.2A HCN Discovery and Readiness Validation' `
                -Results $results `
                -OverallOutcome 'PassedWithFindings' `
                -ContextSummary @{
                    Cluster = 'TESTAZCLUSTER01'
                    ReadOnly = $true
                }

            Test-Path `
                -LiteralPath $report.HtmlPath `
                -PathType Leaf |
                Should Be $true

            Test-Path `
                -LiteralPath $report.JsonPath `
                -PathType Leaf |
                Should Be $true

            $report.Summary.Total |
                Should Be 2

            $report.Summary.Passed |
                Should Be 1

            $report.Summary.Findings |
                Should Be 1

            $html = Get-Content `
                -LiteralPath $report.HtmlPath `
                -Raw

            $html |
                Should Match 'Test-NICState'

            $html |
                Should Match 'Test-RdmaState'

            $html |
                Should Match 'Management1'
        }
        finally {
            Remove-Item `
                -LiteralPath $temporaryRunDirectory `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    It 'redacts secret-like property values from JSON report output' {
        $temporaryRunDirectory = Join-Path `
            $env:TEMP `
            ("validation-findings-redaction-" + [guid]::NewGuid().ToString('N'))

        try {
            New-Item `
                -ItemType Directory `
                -Force `
                -Path $temporaryRunDirectory |
                Out-Null

            $report = & $reportScriptPath `
                -RunDirectory $temporaryRunDirectory `
                -Site 'TEST' `
                -ProfileName 'HcnComplianceValidation' `
                -DisplayName '1.2C HCN Compliance Validation' `
                -Results @(
                    [pscustomobject]@{
                        Operation = 'Test-Example'
                        Node = 'TESTHCN01'
                        Status = 'Passed'
                        Classification = 'Compliant'
                        Summary = 'Example validation.'
                        Details = [pscustomobject]@{
                            password = 'DoNotExpose'
                            token = 'DoNotExpose'
                            safeValue = 'Visible'
                        }
                    }
                ) `
                -OverallOutcome 'Passed'

            $json = Get-Content `
                -LiteralPath $report.JsonPath `
                -Raw

            $json |
                Should Not Match 'DoNotExpose'

            $json |
                Should Match '\[REDACTED\]'

            $json |
                Should Match 'Visible'
        }
        finally {
            Remove-Item `
                -LiteralPath $temporaryRunDirectory `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}