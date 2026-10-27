#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigValue {
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

function Test-ValidWindowsComputerName {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$AllowHyphens
    )

    $pattern = if ($AllowHyphens) {
        '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?$'
    }
    else {
        '^[A-Z0-9]{1,15}$'
    }

    return (
        $Name -match $pattern -and
        $Name.Length -le 15
    )
}

$config = $Context.Config

if ($null -eq $config) {
    throw 'Factory context does not contain Config.'
}

$errors = [System.Collections.Generic.List[string]]::new()

$site = Get-ConfigValue -Object $config -Name 'site'
$naming = Get-ConfigValue -Object $config -Name 'naming'
$cluster = Get-ConfigValue -Object $config -Name 'cluster'
$nodes = @(
    Get-ConfigValue `
        -Object $config `
        -Name 'nodes'
)

$siteName = [string](
    Get-ConfigValue `
        -Object $site `
        -Name 'name'
)

$clusterName = [string](
    Get-ConfigValue `
        -Object $cluster `
        -Name 'name'
)

$siteProfile = Get-ConfigValue `
    -Object $config `
    -Name 'site_profile'

$siteProfileName = [string](
    Get-ConfigValue `
        -Object $siteProfile `
        -Name 'name'
)

$validationMode = [string](
    Get-ConfigValue `
        -Object $naming `
        -Name 'validation_mode'
)

$allowHyphens = (
    (Get-ConfigValue `
        -Object $naming `
        -Name 'allow_hyphenated_node_names') -eq $true
)

if ($validationMode -eq 'GeneralWindowsHost') {
    if ($siteName -notmatch '^[A-Za-z0-9_-]+$') {
        [void]$errors.Add('site.name is missing or invalid.')
    }

    if (
        [string]::IsNullOrWhiteSpace($clusterName) -or
        $clusterName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$'
    ) {
        [void]$errors.Add(
            'cluster.name is missing or contains invalid characters.'
        )
    }

    $topology = Get-ConfigValue `
        -Object $site `
        -Name 'topology'

    $declaredNodeCount = Get-ConfigValue `
        -Object $topology `
        -Name 'phase1_node_count'

    if ($null -eq $declaredNodeCount) {
        [void]$errors.Add(
            'site.topology.phase1_node_count is required.'
        )
    }
    elseif ([int]$declaredNodeCount -ne $nodes.Count) {
        [void]$errors.Add(
            "site.topology.phase1_node_count $declaredNodeCount does not " +
            "match configured node count $($nodes.Count)."
        )
    }

    if ($nodes.Count -lt 1) {
        [void]$errors.Add(
            'At least one node is required.'
        )
    }

    $actualNodeNames = [System.Collections.Generic.List[string]]::new()
    $actualNodeNumbers = [System.Collections.Generic.List[string]]::new()

    foreach ($node in $nodes) {
        $nodeName = [string](
            Get-ConfigValue `
                -Object $node `
                -Name 'name'
        )

        $nodeNumber = [string](
            Get-ConfigValue `
                -Object $node `
                -Name 'node_number'
        )

        if ([string]::IsNullOrWhiteSpace($nodeName)) {
            [void]$errors.Add('A configured node is missing name.')
            continue
        }

        [void]$actualNodeNames.Add($nodeName)

        if (
            -not (
                Test-ValidWindowsComputerName `
                    -Name $nodeName `
                    -AllowHyphens $allowHyphens
            )
        ) {
            [void]$errors.Add(
                "Node $nodeName is not a valid Windows computer name."
            )
        }

        if ($nodeNumber -notmatch '^\d{2}$') {
            [void]$errors.Add(
                "Node $nodeName node_number must be a two-digit value."
            )
        }
        elseif ($actualNodeNumbers -contains $nodeNumber) {
            [void]$errors.Add(
                "Duplicate node_number value: $nodeNumber"
            )
        }
        else {
            [void]$actualNodeNumbers.Add($nodeNumber)
        }
    }

    $duplicateNames = @(
        $actualNodeNames |
            Group-Object |
            Where-Object {
                $_.Count -gt 1
            } |
            Select-Object -ExpandProperty Name
    )

    foreach ($duplicateName in $duplicateNames) {
        [void]$errors.Add("Duplicate node name: $duplicateName")
    }

    if ($errors.Count -gt 0) {
        throw (
            "Naming convention validation failed:`n - " +
            ($errors -join "`n - ")
        )
    }

    return [pscustomobject]@{
        Passed      = $true
        Check       = 'Test-NamingConvention'
        Site        = $siteName
        Cluster     = $clusterName
        Nodes       = $actualNodeNames.ToArray()
        SiteProfile = $siteProfileName
        NamingMode  = $validationMode
        Summary     = (
            "General Windows host naming validated for site $siteName, " +
            "cluster $clusterName, and $($actualNodeNames.Count) node(s)."
        )
        ValidatedAt = [datetime]::UtcNow.ToString('o')
    }
}

$classification = [string](
    Get-ConfigValue `
        -Object $naming `
        -Name 'classification'
)

$siteId = [string](
    Get-ConfigValue `
        -Object $naming `
        -Name 'site_id'
)

$domainShortName = [string](
    Get-ConfigValue `
        -Object $naming `
        -Name 'domain_short_name'
)

if ($siteName -ne 'NRFT') {
    [void]$errors.Add("Expected site.name NRFT. Found: $siteName")
}

if ($classification -ne 'NAEA') {
    [void]$errors.Add(
        "Expected naming.classification NAEA. Found: $classification"
    )
}

if ($siteId -ne 'NRFT') {
    [void]$errors.Add("Expected naming.site_id NRFT. Found: $siteId")
}

if ($domainShortName -ne 'adds') {
    [void]$errors.Add(
        "Expected naming.domain_short_name adds. Found: $domainShortName"
    )
}

$expectedClusterName = 'NRFTAZCLUSTER01'

if ($clusterName -ne $expectedClusterName) {
    [void]$errors.Add(
        "Expected cluster.name $expectedClusterName. Found: $clusterName"
    )
}

if ($nodes.Count -ne 2) {
    [void]$errors.Add(
        "Expected exactly two nodes. Found: $($nodes.Count)"
    )
}

$expectedNodeNames = @(
    'NAEANRFTHCN01',
    'NAEANRFTHCN02'
)

$actualNodeNames = [System.Collections.Generic.List[string]]::new()

foreach ($node in $nodes) {
    $nodeName = [string](
        Get-ConfigValue `
            -Object $node `
            -Name 'name'
    )

    $nodeNumber = [string](
        Get-ConfigValue `
            -Object $node `
            -Name 'node_number'
    )

    if ([string]::IsNullOrWhiteSpace($nodeName)) {
        [void]$errors.Add('A configured node is missing name.')
        continue
    }

    [void]$actualNodeNames.Add($nodeName)

    if (
        -not (
            Test-ValidWindowsComputerName `
                -Name $nodeName `
                -AllowHyphens $false
        )
    ) {
        [void]$errors.Add(
            "Node $nodeName is not a valid Windows computer name."
        )
    }

    if ($nodeNumber -notmatch '^\d{2}$') {
        [void]$errors.Add(
            "Node $nodeName node_number must be a two-digit value."
        )
        continue
    }

    $expectedNodeName = '{0}{1}HCN{2}' -f `
        $classification, `
        $siteId, `
        $nodeNumber

    if ($nodeName -ne $expectedNodeName) {
        [void]$errors.Add(
            "Node name mismatch. Expected $expectedNodeName; found $nodeName."
        )
    }
}

$duplicateNames = @(
    $actualNodeNames |
        Group-Object |
        Where-Object {
            $_.Count -gt 1
        } |
        Select-Object -ExpandProperty Name
)

foreach ($duplicateName in $duplicateNames) {
    [void]$errors.Add("Duplicate node name: $duplicateName")
}

foreach ($expectedNodeName in $expectedNodeNames) {
    if ($actualNodeNames -notcontains $expectedNodeName) {
        [void]$errors.Add(
            "Required Phase 1 node is missing: $expectedNodeName"
        )
    }
}

if ($errors.Count -gt 0) {
    throw (
        "Naming convention validation failed:`n - " +
        ($errors -join "`n - ")
    )
}

return [pscustomobject]@{
    Passed      = $true
    Check       = 'Test-NamingConvention'
    Site        = $siteName
    Cluster     = $clusterName
    Nodes       = $actualNodeNames.ToArray()
    SiteProfile = $siteProfileName
    NamingMode  = 'LegacyNRFT'
    ValidatedAt = [datetime]::UtcNow.ToString('o')
}