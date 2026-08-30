Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "PluginManager.psm1") -Force

function Get-OrchestrationOptionalValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function ConvertTo-OrchestrationHashtable {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = ConvertTo-OrchestrationHashtable $Value[$key]
        }
        return $result
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-OrchestrationHashtable $property.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(ConvertTo-OrchestrationHashtable $item)
        }
        return $items
    }
    return $Value
}

function Get-CatalogDependencyIds {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry)

    $dependencies = @()
    foreach ($dependency in @(Get-OrchestrationOptionalValue -Object $Entry -Name "dependsOn" -Default @())) {
        if ($dependency) {
            $dependencies += ([string]$dependency).ToLowerInvariant()
        }
    }
    return $dependencies
}

function Get-CatalogEntryById {
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$Id
    )

    foreach ($entry in @($Catalog.plugins)) {
        if (([string]$entry.id).Equals($Id, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $entry
        }
    }
    return $null
}

function Test-DependencyNode {
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Stack
    )

    $currentState = if ($State.ContainsKey($Id)) { [int]$State[$Id] } else { 0 }
    if ($currentState -eq 2) {
        return
    }
    if ($currentState -eq 1) {
        $cycle = @($Stack) + $Id
        throw "Plugin dependency cycle detected: $($cycle -join ' -> ')"
    }

    $State[$Id] = 1
    $Stack.Add($Id)
    $entry = Get-CatalogEntryById -Catalog $Catalog -Id $Id
    foreach ($dependency in @(Get-CatalogDependencyIds -Entry $entry)) {
        Test-DependencyNode -Catalog $Catalog -Id $dependency -State $State -Stack $Stack
    }
    $Stack.RemoveAt($Stack.Count - 1)
    $State[$Id] = 2
}

function Assert-CatalogDependencyGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog)

    $known = @{}
    foreach ($entry in @($Catalog.plugins)) {
        $id = ([string]$entry.id).ToLowerInvariant()
        $known[$id] = $true

        $seen = @{}
        foreach ($dependency in @(Get-CatalogDependencyIds -Entry $entry)) {
            if ($dependency -eq $id) {
                throw "Plugin '$id' cannot depend on itself."
            }
            if ($seen.ContainsKey($dependency)) {
                throw "Plugin '$id' declares duplicate dependency '$dependency'."
            }
            $seen[$dependency] = $true
        }
    }

    foreach ($entry in @($Catalog.plugins)) {
        $id = ([string]$entry.id).ToLowerInvariant()
        foreach ($dependency in @(Get-CatalogDependencyIds -Entry $entry)) {
            if (-not $known.ContainsKey($dependency)) {
                throw "Plugin '$id' depends on unknown managed plugin '$dependency'."
            }
        }
    }

    $state = @{}
    $stack = New-Object System.Collections.Generic.List[string]
    foreach ($id in @($known.Keys | Sort-Object)) {
        Test-DependencyNode -Catalog $Catalog -Id $id -State $state -Stack $stack
    }
}

function Add-DependencyNodeToOrder {
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][hashtable]$Visited,
        [Parameter(Mandatory)][System.Collections.Generic.List[string]]$Result
    )

    $normalized = $Id.ToLowerInvariant()
    if ($Visited.ContainsKey($normalized)) {
        return
    }
    $Visited[$normalized] = $true

    $entry = Get-CatalogEntryById -Catalog $Catalog -Id $normalized
    if (-not $entry) {
        throw "Unknown managed plugin '$Id'."
    }
    foreach ($dependency in @(Get-CatalogDependencyIds -Entry $entry)) {
        Add-DependencyNodeToOrder -Catalog $Catalog -Id $dependency -Visited $Visited -Result $Result
    }
    $Result.Add($normalized)
}

function Get-DependencyOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [string]$RootId
    )

    Assert-CatalogDependencyGraph -Catalog $Catalog
    $visited = @{}
    $result = New-Object System.Collections.Generic.List[string]

    if ($RootId) {
        Add-DependencyNodeToOrder -Catalog $Catalog -Id $RootId -Visited $visited -Result $result
    }
    else {
        foreach ($entry in @($Catalog.plugins | Sort-Object id)) {
            $entryId = [string]$entry.id
            Add-DependencyNodeToOrder -Catalog $Catalog -Id $entryId -Visited $visited -Result $result
        }
    }

    return @($result)
}

function Get-InstalledItemByManagedId {
    param(
        [Parameter(Mandatory)][object[]]$Inventory,
        [Parameter(Mandatory)][string]$ManagedId
    )

    $matches = @($Inventory | Where-Object {
        $_.ManagedId -and ([string]$_.ManagedId).Equals($ManagedId, [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($matches.Count -gt 1) {
        throw "Multiple installed JARs match managed plugin '$ManagedId'."
    }
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    return $null
}

function Resolve-OrchestrationInstalledPlugin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][object[]]$Inventory
    )

    $normalized = $Reference.ToLowerInvariant()
    $matches = @($Inventory | Where-Object {
        ($_.ManagedId -and ([string]$_.ManagedId).Equals($Reference, [System.StringComparison]::OrdinalIgnoreCase)) -or
        ([string]$_.Name).Equals($Reference, [System.StringComparison]::OrdinalIgnoreCase) -or
        ([string]$_.FileName).Equals($Reference, [System.StringComparison]::OrdinalIgnoreCase) -or
        ([System.IO.Path]::GetFileNameWithoutExtension([string]$_.FileName)).ToLowerInvariant() -eq $normalized
    })

    if ($matches.Count -gt 1) {
        $paths = ($matches | ForEach-Object { $_.Path }) -join [Environment]::NewLine
        throw "Plugin reference '$Reference' is ambiguous. Matching JARs:`n$paths"
    }
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    return $null
}

function Get-InstalledDependents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][object[]]$Inventory,
        [Parameter(Mandatory)][string]$ManagedId,
        [switch]$EnabledOnly
    )

    $result = @()
    foreach ($entry in @($Catalog.plugins)) {
        $depends = @(Get-CatalogDependencyIds -Entry $entry)
        if ($depends -notcontains $ManagedId.ToLowerInvariant()) {
            continue
        }

        $installed = Get-InstalledItemByManagedId -Inventory $Inventory -ManagedId ([string]$entry.id)
        if (-not $installed) {
            continue
        }
        if ($EnabledOnly -and -not $installed.Enabled) {
            continue
        }
        $result += $installed
    }
    return $result
}

function Assert-PluginMutationAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][object[]]$Inventory,
        [Parameter(Mandatory)]$Item,
        [ValidateSet("remove", "disable")][string]$Operation
    )

    if (-not $Item.ManagedId) {
        return
    }

    $dependents = if ($Operation -eq "disable") {
        @(Get-InstalledDependents -Catalog $Catalog -Inventory $Inventory -ManagedId $Item.ManagedId -EnabledOnly)
    }
    else {
        @(Get-InstalledDependents -Catalog $Catalog -Inventory $Inventory -ManagedId $Item.ManagedId)
    }

    if ($dependents.Count -gt 0) {
        $names = ($dependents | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ", "
        throw "Cannot $Operation $($Item.Name) because installed plugin(s) depend on it: $names"
    }
}

function Ensure-PluginDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$PluginId,
        [Parameter(Mandatory)][string]$ServerPath,
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][string]$CatalogPath,
        [ValidateRange(1, 100)][int]$BackupCount,
        [switch]$DryRun
    )

    $results = @()
    $order = @(Get-DependencyOrder -Catalog $Catalog -RootId $PluginId)
    if ($order.Count -le 1) {
        return $results
    }

    foreach ($dependencyId in @($order | Select-Object -First ($order.Count - 1))) {
        $inventory = @(Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $Catalog)
        $installed = Get-InstalledItemByManagedId -Inventory $inventory -ManagedId $dependencyId

        if (-not $installed) {
            $parameters = @{
                Command = "install"
                Plugin = $dependencyId
                ServerPath = $ServerPath
                ServiceName = $ServiceName
                CatalogPath = $CatalogPath
                BackupCount = $BackupCount
                DryRun = $DryRun
            }
            $results += Invoke-PluginManager @parameters
            continue
        }

        if (-not $installed.Enabled) {
            $parameters = @{
                Command = "enable"
                Plugin = $dependencyId
                ServerPath = $ServerPath
                ServiceName = $ServiceName
                CatalogPath = $CatalogPath
                BackupCount = $BackupCount
                DryRun = $DryRun
            }
            $results += Invoke-PluginManager @parameters
        }
    }

    return $results
}

function Get-OrchestrationPaths {
    param([Parameter(Mandatory)][string]$ServerPath)

    $root = Join-Path $ServerPath "deploy\plugin-manager"
    return [pscustomobject]@{
        Server = $ServerPath
        Plugins = Join-Path $ServerPath "plugins"
        Disabled = Join-Path $ServerPath "plugins-disabled"
        Root = $root
        Downloads = Join-Path $root "downloads"
        Backups = Join-Path $root "backups"
        State = Join-Path $root "state.json"
    }
}

function Ensure-OrchestrationPaths {
    param([Parameter(Mandatory)]$Paths)

    if (-not (Test-Path -LiteralPath $Paths.Server -PathType Container)) {
        throw "Minecraft server directory does not exist: $($Paths.Server)"
    }
    if (-not (Test-Path -LiteralPath $Paths.Plugins -PathType Container)) {
        throw "Minecraft plugins directory does not exist: $($Paths.Plugins)"
    }

    foreach ($path in @($Paths.Disabled, $Paths.Root, $Paths.Downloads, $Paths.Backups)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function Assert-OrchestrationAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this command from PowerShell as Administrator."
    }
}

function Wait-OrchestrationServiceState {
    param(
        [Parameter(Mandatory)][System.ServiceProcess.ServiceController]$Service,
        [Parameter(Mandatory)][System.ServiceProcess.ServiceControllerStatus]$Status,
        [int]$TimeoutSeconds = 60
    )

    $Service.WaitForStatus($Status, [TimeSpan]::FromSeconds($TimeoutSeconds))
    $Service.Refresh()
    if ($Service.Status -ne $Status) {
        throw "Service $($Service.ServiceName) did not reach state $Status."
    }
}

function Invoke-OrchestrationServiceTransaction {
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][scriptblock]$Mutation,
        [Parameter(Mandatory)][scriptblock]$Rollback
    )

    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    $wasRunning = $service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped

    try {
        if ($wasRunning) {
            Stop-Service -Name $ServiceName -Force
            $service.Refresh()
            Wait-OrchestrationServiceState -Service $service -Status ([System.ServiceProcess.ServiceControllerStatus]::Stopped)
        }

        & $Mutation

        if ($wasRunning) {
            Start-Service -Name $ServiceName
            $service.Refresh()
            Wait-OrchestrationServiceState -Service $service -Status ([System.ServiceProcess.ServiceControllerStatus]::Running)
        }
    }
    catch {
        $original = $_
        try {
            $service.Refresh()
            if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
                $service.Refresh()
                Wait-OrchestrationServiceState -Service $service -Status ([System.ServiceProcess.ServiceControllerStatus]::Stopped)
            }

            & $Rollback

            if ($wasRunning) {
                Start-Service -Name $ServiceName
                $service.Refresh()
                Wait-OrchestrationServiceState -Service $service -Status ([System.ServiceProcess.ServiceControllerStatus]::Running)
            }
        }
        catch {
            Write-Error "Batch rollback also failed: $($_.Exception.Message)"
        }
        throw $original
    }
}

function Read-OrchestrationState {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [ordered]@{ schemaVersion = 1; plugins = [ordered]@{} }
    }

    $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $state = ConvertTo-OrchestrationHashtable $parsed
    if ($state.schemaVersion -ne 1) {
        throw "Unsupported PluginManager state schema version: $($state.schemaVersion)"
    }
    if (-not $state.Contains("plugins")) {
        $state.plugins = [ordered]@{}
    }
    return $state
}

function Write-OrchestrationJsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $temporary = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Save-OrchestrationStateBestEffort {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )

    try {
        Write-OrchestrationJsonAtomic -Path $Path -Value $State
    }
    catch {
        Write-Warning "Batch update succeeded, but PluginManager state could not be updated: $($_.Exception.Message)"
    }
}

function Get-OrchestrationStateRecord {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$ManagedId
    )

    if ($State.plugins.Contains($ManagedId)) {
        return $State.plugins[$ManagedId]
    }
    return $null
}

function New-OrchestrationBackup {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$ManagedId,
        [string]$ReleaseTag
    )

    $directory = Join-Path $Paths.Backups $ManagedId.ToLowerInvariant()
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
    $backupPath = Join-Path $directory "$timestamp-$($Item.FileName)"
    Copy-Item -LiteralPath $Item.Path -Destination $backupPath -Force

    Write-OrchestrationJsonAtomic -Path "$backupPath.json" -Value ([ordered]@{
        pluginName = $Item.Name
        version = $Item.Version
        managedId = $ManagedId
        originalFileName = $Item.FileName
        enabled = [bool]$Item.Enabled
        releaseTag = $ReleaseTag
        createdUtc = [DateTimeOffset]::UtcNow.ToString("O")
    })

    return $backupPath
}

function Remove-OrchestrationOldBackups {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$ManagedId,
        [ValidateRange(1, 100)][int]$BackupCount
    )

    $directory = Join-Path $Paths.Backups $ManagedId.ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        return
    }

    foreach ($jar in @(Get-ChildItem -LiteralPath $directory -File -Filter "*.jar" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $BackupCount)) {
        Remove-Item -LiteralPath $jar.FullName -Force
        Remove-Item -LiteralPath "$($jar.FullName).json" -Force -ErrorAction SilentlyContinue
    }
}

function Get-ManagedUpdatePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$ServerPath,
        [string]$Channel
    )

    Assert-CatalogDependencyGraph -Catalog $Catalog
    $inventory = @(Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $Catalog)
    $order = @(Get-DependencyOrder -Catalog $Catalog)
    $plan = @()

    foreach ($id in $order) {
        $entry = Get-CatalogEntryById -Catalog $Catalog -Id $id
        $installed = Get-InstalledItemByManagedId -Inventory $inventory -ManagedId $id
        if (-not $installed) {
            continue
        }

        if ($installed.Enabled) {
            foreach ($dependencyId in @(Get-CatalogDependencyIds -Entry $entry)) {
                $dependency = Get-InstalledItemByManagedId -Inventory $inventory -ManagedId $dependencyId
                if (-not $dependency) {
                    throw "Enabled plugin '$($installed.Name)' requires managed plugin '$dependencyId', but it is not installed."
                }
                if (-not $dependency.Enabled) {
                    throw "Enabled plugin '$($installed.Name)' requires managed plugin '$dependencyId', but it is disabled."
                }
            }
        }

        $selectedChannel = if ($Channel) {
            $Channel
        }
        else {
            [string](Get-OrchestrationOptionalValue -Object $entry -Name "defaultChannel" -Default "Stable")
        }
        $release = Get-GitHubRelease -Repository $entry.repository -Channel $selectedChannel
        $releaseVersion = ([string]$release.tag_name) -replace '^v', ''

        if (([string]$installed.Version).Equals($releaseVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $plan += [pscustomobject]@{
            Id = $id
            Name = $installed.Name
            FromVersion = $installed.Version
            Version = $releaseVersion
            ReleaseTag = [string]$release.tag_name
            Release = $release
            Entry = $entry
            Installed = $installed
            Enabled = [bool]$installed.Enabled
        }
    }

    return $plan
}

function Stage-ManagedUpdate {
    param(
        [Parameter(Mandatory)]$PlanItem,
        [Parameter(Mandatory)][string]$DownloadRoot
    )

    $entry = $PlanItem.Entry
    $release = $PlanItem.Release
    $asset = Resolve-ReleaseAsset -Release $release -Pattern $entry.assetPattern -Purpose "plugin JAR"
    $directory = Join-Path $DownloadRoot $PlanItem.Id
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $downloadedJar = Join-Path $directory ([string]$asset.name)
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadedJar -UseBasicParsing

    $checksumParameters = @{
        Release = $release
        JarAsset = $asset
        ChecksumAssetPattern = Get-OrchestrationOptionalValue -Object $entry -Name "checksumAssetPattern"
        DownloadDirectory = $directory
    }
    $expectedHash = Get-ExpectedSha256 @checksumParameters
    $actualHash = (Get-FileHash -LiteralPath $downloadedJar -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA-256 verification failed for $($PlanItem.Name). Expected $expectedHash, got $actualHash."
    }

    $metadata = Get-PluginJarMetadata -Path $downloadedJar
    if (-not $metadata.Name.Equals([string]$entry.pluginName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Downloaded JAR declares plugin '$($metadata.Name)', expected '$($entry.pluginName)'."
    }

    $targetDirectory = [System.IO.Path]::GetDirectoryName([string]$PlanItem.Installed.Path)
    $targetPath = Join-Path $targetDirectory ([string]$entry.installedFile)

    return [pscustomobject]@{
        Id = $PlanItem.Id
        Name = $PlanItem.Name
        FromVersion = $PlanItem.FromVersion
        Version = $metadata.Version
        ReleaseTag = $PlanItem.ReleaseTag
        Entry = $entry
        Installed = $PlanItem.Installed
        Enabled = $PlanItem.Enabled
        DownloadedJar = $downloadedJar
        Sha256 = $actualHash
        TargetPath = $targetPath
    }
}

function Invoke-UpdateAll {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$ServerPath,
        [Parameter(Mandatory)][string]$ServiceName,
        [ValidateRange(1, 100)][int]$BackupCount = 10,
        [string]$Channel,
        [switch]$DryRun
    )

    $paths = Get-OrchestrationPaths -ServerPath $ServerPath
    Ensure-OrchestrationPaths -Paths $paths
    $plan = @(Get-ManagedUpdatePlan -Catalog $Catalog -ServerPath $ServerPath -Channel $Channel)

    if ($plan.Count -eq 0) {
        return @()
    }

    if ($DryRun) {
        return @($plan | ForEach-Object {
            [pscustomobject]@{
                Action = "update"
                Name = $_.Name
                FromVersion = $_.FromVersion
                Version = $_.Version
                ReleaseTag = $_.ReleaseTag
                Enabled = $_.Enabled
                Changed = $false
                DryRun = $true
            }
        })
    }

    Assert-OrchestrationAdministrator
    $batchDirectory = Join-Path $paths.Downloads ("batch-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $batchDirectory -Force | Out-Null

    try {
        $staged = @()
        foreach ($item in $plan) {
            $staged += Stage-ManagedUpdate -PlanItem $item -DownloadRoot $batchDirectory
        }

        $targetKeys = @{}
        foreach ($item in $staged) {
            $key = ([string]$item.TargetPath).ToLowerInvariant()
            if ($targetKeys.ContainsKey($key)) {
                throw "Batch update contains duplicate target path: $($item.TargetPath)"
            }
            $targetKeys[$key] = $true

            if ((Test-Path -LiteralPath $item.TargetPath) -and -not ([string]$item.TargetPath).Equals([string]$item.Installed.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Batch update target already exists: $($item.TargetPath)"
            }
        }

        $state = Read-OrchestrationState -Path $paths.State
        $backups = @{}
        foreach ($item in $staged) {
            $record = Get-OrchestrationStateRecord -State $state -ManagedId $item.Id
            $backupParameters = @{
                Paths = $paths
                Item = $item.Installed
                ManagedId = $item.Id
                ReleaseTag = Get-OrchestrationOptionalValue -Object $record -Name "releaseTag"
            }
            $backups[$item.Id] = New-OrchestrationBackup @backupParameters
        }

        Invoke-OrchestrationServiceTransaction -ServiceName $ServiceName -Mutation {
            foreach ($item in $staged) {
                if (Test-Path -LiteralPath $item.Installed.Path) {
                    Remove-Item -LiteralPath $item.Installed.Path -Force
                }
                Copy-Item -LiteralPath $item.DownloadedJar -Destination $item.TargetPath -Force
            }
        } -Rollback {
            for ($index = $staged.Count - 1; $index -ge 0; $index--) {
                $item = $staged[$index]
                if (Test-Path -LiteralPath $item.TargetPath) {
                    Remove-Item -LiteralPath $item.TargetPath -Force
                }
                $backup = $backups[$item.Id]
                if ($backup) {
                    Copy-Item -LiteralPath $backup -Destination $item.Installed.Path -Force
                }
            }
        }

        foreach ($item in $staged) {
            $state.plugins[$item.Id] = [ordered]@{
                pluginName = $item.Name
                managedId = $item.Id
                repository = [string]$item.Entry.repository
                releaseTag = $item.ReleaseTag
                version = $item.Version
                fileName = [string]$item.Entry.installedFile
                enabled = [bool]$item.Enabled
                sha256 = $item.Sha256
                updatedUtc = [DateTimeOffset]::UtcNow.ToString("O")
            }
        }
        Save-OrchestrationStateBestEffort -Path $paths.State -State $state

        foreach ($item in $staged) {
            Remove-OrchestrationOldBackups -Paths $paths -ManagedId $item.Id -BackupCount $BackupCount
        }

        return @($staged | ForEach-Object {
            [pscustomobject]@{
                Action = "update"
                Name = $_.Name
                FromVersion = $_.FromVersion
                Version = $_.Version
                ReleaseTag = $_.ReleaseTag
                Enabled = $_.Enabled
                Path = $_.TargetPath
                Changed = $true
            }
        })
    }
    finally {
        Remove-Item -LiteralPath $batchDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-DependencyAwareInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$Plugin,
        [Parameter(Mandatory)][string]$ServerPath,
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][string]$CatalogPath,
        [ValidateRange(1, 100)][int]$BackupCount,
        [string]$Version,
        [string]$Channel,
        [switch]$DryRun,
        [switch]$RequireInstalled
    )

    $entry = Get-CatalogEntry -Catalog $Catalog -Reference $Plugin
    if (-not $entry) {
        throw "Plugin '$Plugin' is not in the managed catalog."
    }

    if ($RequireInstalled) {
        $inventory = @(Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $Catalog)
        if (-not (Get-InstalledItemByManagedId -Inventory $inventory -ManagedId ([string]$entry.id))) {
            throw "Plugin '$Plugin' is not installed. Use install first."
        }
    }

    $dependencyParameters = @{
        Catalog = $Catalog
        PluginId = [string]$entry.id
        ServerPath = $ServerPath
        ServiceName = $ServiceName
        CatalogPath = $CatalogPath
        BackupCount = $BackupCount
        DryRun = $DryRun
    }
    $results = @(Ensure-PluginDependencies @dependencyParameters)

    $parameters = @{
        Command = if ($RequireInstalled) { "update" } else { "install" }
        Plugin = [string]$entry.id
        ServerPath = $ServerPath
        ServiceName = $ServiceName
        CatalogPath = $CatalogPath
        BackupCount = $BackupCount
        DryRun = $DryRun
    }
    if ($Version) {
        $parameters.Version = $Version
    }
    if ($Channel) {
        $parameters.Channel = $Channel
    }

    $results += Invoke-PluginManager @parameters
    return $results
}

function Invoke-DependencyAwareEnable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$Plugin,
        [Parameter(Mandatory)][string]$ServerPath,
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][string]$CatalogPath,
        [ValidateRange(1, 100)][int]$BackupCount,
        [switch]$DryRun
    )

    $inventory = @(Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $Catalog)
    $item = Resolve-OrchestrationInstalledPlugin -Reference $Plugin -Inventory $inventory
    if (-not $item) {
        throw "Plugin '$Plugin' is not installed."
    }

    $results = @()
    if ($item.ManagedId) {
        $dependencyParameters = @{
            Catalog = $Catalog
            PluginId = [string]$item.ManagedId
            ServerPath = $ServerPath
            ServiceName = $ServiceName
            CatalogPath = $CatalogPath
            BackupCount = $BackupCount
            DryRun = $DryRun
        }
        $results += Ensure-PluginDependencies @dependencyParameters
    }

    $parameters = @{
        Command = "enable"
        Plugin = $Plugin
        ServerPath = $ServerPath
        ServiceName = $ServiceName
        CatalogPath = $CatalogPath
        BackupCount = $BackupCount
        DryRun = $DryRun
    }
    $results += Invoke-PluginManager @parameters
    return $results
}

function Invoke-DependencyGuardedMutation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [ValidateSet("remove", "disable")][string]$Command,
        [Parameter(Mandatory)][string]$Plugin,
        [Parameter(Mandatory)][string]$ServerPath,
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][string]$CatalogPath,
        [ValidateRange(1, 100)][int]$BackupCount,
        [switch]$DryRun,
        [switch]$Force
    )

    $inventory = @(Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $Catalog)
    $item = Resolve-OrchestrationInstalledPlugin -Reference $Plugin -Inventory $inventory
    if (-not $item) {
        throw "Plugin '$Plugin' is not installed."
    }

    Assert-PluginMutationAllowed -Catalog $Catalog -Inventory $inventory -Item $item -Operation $Command

    $parameters = @{
        Command = $Command
        Plugin = $Plugin
        ServerPath = $ServerPath
        ServiceName = $ServiceName
        CatalogPath = $CatalogPath
        BackupCount = $BackupCount
        DryRun = $DryRun
        Force = $Force
    }
    return Invoke-PluginManager @parameters
}

Export-ModuleMember -Function @(
    "Assert-CatalogDependencyGraph",
    "Get-CatalogDependencyIds",
    "Get-DependencyOrder",
    "Get-InstalledDependents",
    "Assert-PluginMutationAllowed",
    "Resolve-OrchestrationInstalledPlugin",
    "Ensure-PluginDependencies",
    "Get-ManagedUpdatePlan",
    "Invoke-UpdateAll",
    "Invoke-DependencyAwareInstall",
    "Invoke-DependencyAwareEnable",
    "Invoke-DependencyGuardedMutation"
)
