$phase13Operations = @(
    'Invoke-AzureLocalNodeBootstrap',
    'Test-AzureLocalNodeBootstrapState'
)

$adapterConfig = Get-Content `
    .\protected\adapters.yaml `
    -Raw |
    ConvertFrom-Yaml `
    -Ordered

$adapterMap = if (
    $adapterConfig -is [System.Collections.IDictionary] -and
    $adapterConfig.Contains('adapters')
) {
    $adapterConfig['adapters']
}
else {
    $adapterConfig
}

foreach ($operation in $phase13Operations) {
    $relativePath = $adapterMap[$operation]

    [pscustomobject]@{
        Operation   = $operation
        AdapterPath = $relativePath
        Exists      = if ([string]::IsNullOrWhiteSpace([string]$relativePath)) {
            $false
        }
        else {
            Test-Path `
                -LiteralPath (Join-Path $PWD $relativePath) `
                -PathType Leaf
        }
    }
} |
    Format-Table -AutoSize