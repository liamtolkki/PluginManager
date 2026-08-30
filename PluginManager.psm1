Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

$script:GitHubHeaders = @{
    Accept = "application/vnd.github+json"
    "User-Agent" = "Minecraft-PluginManager"
    "X-GitHub-Api-Version" = "2022-11-28"
}

function Normalize-PluginKey {
    param([Parameter(Mandatory)][string]$Value)

    return ($Value.ToLowerInvariant() -replace "[^a-z0-9._-]", "-")
}

function Read-JsonHashtable {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $temporary = "$Path.tmp"
    $json = $Value | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $temporary -Value $json -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-PluginCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath)

    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        throw "Plugin catalog does not exist: $CatalogPath"
    }

    $catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
    if ($catalog.schemaVersion -ne 1) {
        throw "Unsupported plugin catalog schema version: $($catalog.schemaVersion)"
    }

    $seenIds = @{}
    foreach ($plugin in @($catalog.plugins)) {
        if (-not $plugin.id -or -not $plugin.pluginName -or -not $plugin.repository -or -not $plugin.assetPattern -or -not $plugin.installedFile) {
            throw "Every catalog entry must define id, pluginName, repository, assetPattern, and installedFile."
        }

        $id = Normalize-PluginKey $plugin.id
        if ($seenIds.ContainsKey($id)) {
            throw "Duplicate plugin catalog id: $id"
        }
        $seenIds[$id] = $true

        if ($plugin.defaultChannel -and $plugin.defaultChannel -notin @("Stable", "Prerelease")) {
            throw "Invalid default channel for $($plugin.id): $($plugin.defaultChannel)"
        }

        [void][regex]::new([string]$plugin.assetPattern)
        if ($plugin.checksumAssetPattern) {
            [void][regex]::new([string]$plugin.checksumAssetPattern)
        }
        foreach ($pattern in @($plugin.installedFilePatterns)) {
            [void][regex]::new([string]$pattern)
        }
    }

    return $catalog
}

function Get-CatalogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$Reference
    )

    $normalized = Normalize-PluginKey $Reference
    $matches = @($Catalog.plugins | Where-Object {
        (Normalize-PluginKey ([string]$_.id)) -eq $normalized -or
        ([string]$_.pluginName).Equals($Reference, [System.StringComparison]::OrdinalIgnoreCase)
    })

    if ($matches.Count -eq 0) {
        return $null
    }
    if ($matches.Count -gt 1) {
        throw "Catalog reference is ambiguous: $Reference"
    }
    return $matches[0]
}

function Get-PluginJarMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Plugin JAR does not exist: $Path"
    }

    $archive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
    try {
        $entry = $archive.GetEntry("paper-plugin.yml")
        if ($null -eq $entry) {
            $entry = $archive.GetEntry("plugin.yml")
        }
        if ($null -eq $entry) {
            throw "JAR does not contain plugin.yml or paper-plugin.yml: $Path"
        }

        $reader = [System.IO.StreamReader]::new($entry.Open())
        try {
            $content = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $nameMatch = [regex]::Match($content, '(?m)^\s*name\s*:\s*["'']?([^"''#\r\n]+)')
        $versionMatch = [regex]::Match($content, '(?m)^\s*version\s*:\s*["'']?([^"''#\r\n]+)')

        if (-not $nameMatch.Success) {
            throw "Plugin metadata does not contain a name: $Path"
        }

        return [pscustomobject]@{
            Name = $nameMatch.Groups[1].Value.Trim()
            Version = if ($versionMatch.Success) { $versionMatch.Groups[1].Value.Trim() } else { "unknown" }
            MetadataFile = $entry.FullName
            Path = (Resolve-Path -LiteralPath $Path).Path
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Test-FileMatchesCatalogEntry {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)]$Entry
    )

    if ($FileName.Equals([string]$Entry.installedFile, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    foreach ($pattern in @($Entry.installedFilePatterns)) {
        if ($FileName -match [string]$pattern) {
            return $true
        }
    }

    return $false
}

function Resolve-ManagedIdForJar {
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$PluginName
    )

    $matches = @($Catalog.plugins | Where-Object {
        ([string]$_.pluginName).Equals($PluginName, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Test-FileMatchesCatalogEntry -FileName $FileName -Entry $_)
    })

    if ($matches.Count -eq 1) {
        return [string]$matches[0].id
    }
    return $null
}

function Get-InstalledPluginInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerPath,
        [Parameter(Mandatory)]$Catalog
    )

    $pluginsPath = Join-Path $ServerPath "plugins"
    $disabledPath = Join-Path $ServerPath "plugins-disabled"
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($source in @(
        @{ Path = $pluginsPath; Enabled = $true },
        @{ Path = $disabledPath; Enabled = $false }
    )) {
        if (-not (Test-Path -LiteralPath $source.Path)) {
            continue
        }

        foreach ($jar in Get-ChildItem -LiteralPath $source.Path -File -Filter "*.jar") {
            try {
                $metadata = Get-PluginJarMetadata -Path $jar.FullName
                $pluginName = $metadata.Name
                $version = $metadata.Version
                $metadataError = $null
            }
            catch {
                $pluginName = [System.IO.Path]::GetFileNameWithoutExtension($jar.Name)
                $version = "unknown"
                $metadataError = $_.Exception.Message
            }

            $managedId = Resolve-ManagedIdForJar -Catalog $Catalog -FileName $jar.Name -PluginName $pluginName
            $items.Add([pscustomobject]@{
                Name = $pluginName
                Version = $version
                Enabled = [bool]$source.Enabled
                Managed = ($null -ne $managedId)
                ManagedId = $managedId
                FileName = $jar.Name
                Path = $jar.FullName
                MetadataError = $metadataError
            })
        }
    }

    return @($items)
}

function Resolve-InstalledPlugin {
    param(
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][object[]]$Inventory
    )

    $normalized = Normalize-PluginKey $Reference
    $matches = @($Inventory | Where-Object {
        ($_.ManagedId -and (Normalize-PluginKey ([string]$_.ManagedId)) -eq $normalized) -or
        ([string]$_.Name).Equals($Reference, [System.StringComparison]::OrdinalIgnoreCase) -or
        ([string]$_.FileName).Equals($Reference, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Normalize-PluginKey ([System.IO.Path]::GetFileNameWithoutExtension([string]$_.FileName))) -eq $normalized
    })

    if ($matches.Count -eq 0) {
        return $null
    }
    if ($matches.Count -gt 1) {
        $paths = ($matches | ForEach-Object { $_.Path }) -join [Environment]::NewLine
        throw "Plugin reference '$Reference' is ambiguous. Matching JARs:`n$paths"
    }
    return $matches[0]
}

function Get-GitHubRelease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [string]$Version,
        [ValidateSet("Stable", "Prerelease")][string]$Channel = "Stable"
    )

    if ($Version) {
        $tag = if ($Version.StartsWith("v", [System.StringComparison]::OrdinalIgnoreCase)) { $Version } else { "v$Version" }
        $encodedTag = [System.Uri]::EscapeDataString($tag)
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/tags/$encodedTag" -Headers $script:GitHubHeaders -Method Get
    }

    $releases = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases?per_page=100" -Headers $script:GitHubHeaders -Method Get)
    $release = if ($Channel -eq "Prerelease") {
        $releases | Where-Object { -not $_.draft -and $_.prerelease } | Select-Object -First 1
    }
    else {
        $releases | Where-Object { -not $_.draft -and -not $_.prerelease } | Select-Object -First 1
    }

    if (-not $release) {
        throw "No $Channel release is available for $Repository."
    }
    return $release
}

function Resolve-ReleaseAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Purpose
    )

    $matches = @($Release.assets | Where-Object { [string]$_.name -match $Pattern })
    if ($matches.Count -eq 0) {
        throw "Release $($Release.tag_name) does not contain a $Purpose asset matching '$Pattern'."
    }
    if ($matches.Count -gt 1) {
        throw "Release $($Release.tag_name) contains multiple $Purpose assets matching '$Pattern'."
    }
    return $matches[0]
}

function Get-ExpectedSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)]$JarAsset,
        [string]$ChecksumAssetPattern,
        [Parameter(Mandatory)][string]$DownloadDirectory
    )

    if ($ChecksumAssetPattern) {
        $checksumMatches = @($Release.assets | Where-Object { [string]$_.name -match $ChecksumAssetPattern })
        if ($checksumMatches.Count -gt 1) {
            throw "Release $($Release.tag_name) contains multiple checksum assets matching '$ChecksumAssetPattern'."
        }
        if ($checksumMatches.Count -eq 1) {
            $checksumPath = Join-Path $DownloadDirectory ([string]$checksumMatches[0].name)
            Invoke-WebRequest -Uri $checksumMatches[0].browser_download_url -OutFile $checksumPath -UseBasicParsing
            $hash = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split "\s+")[0].ToLowerInvariant()
            if ($hash -notmatch "^[0-9a-f]{64}$") {
                throw "Checksum asset contains an invalid SHA-256 value."
            }
            return $hash
        }
    }

    $digest = [string]$JarAsset.digest
    if ($digest -match '^sha256:([0-9a-fA-F]{64})$') {
        return $Matches[1].ToLowerInvariant()
    }

    throw "Release $($Release.tag_name) does not provide a usable SHA-256 checksum or GitHub asset digest."
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this command from PowerShell as Administrator."
    }
}

function Get-ManagerPaths {
    param([Parameter(Mandatory)][string]$ServerPath)

    $deployRoot = Join-Path $ServerPath "deploy\plugin-manager"
    return [pscustomobject]@{
        Server = $ServerPath
        Plugins = Join-Path $ServerPath "plugins"
        Disabled = Join-Path $ServerPath "plugins-disabled"
        Root = $deployRoot
        Downloads = Join-Path $deployRoot "downloads"
        Backups = Join-Path $deployRoot "backups"
        State = Join-Path $deployRoot "state.json"
    }
}

function Ensure-ManagerDirectories {
    param([Parameter(Mandatory)]$Paths)

    foreach ($path in @($Paths.Plugins, $Paths.Disabled, $Paths.Root, $Paths.Downloads, $Paths.Backups)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function Get-ManagerState {
    param([Parameter(Mandatory)][string]$StatePath)

    $state = Read-JsonHashtable -Path $StatePath
    if ($null -eq $state) {
        return [ordered]@{
            schemaVersion = 1
            plugins = [ordered]@{}
        }
    }
    if ($state.schemaVersion -ne 1) {
        throw "Unsupported PluginManager state schema version: $($state.schemaVersion)"
    }
    if (-not $state.ContainsKey("plugins")) {
        $state.plugins = [ordered]@{}
    }
    return $state
}

function Save-ManagerStateBestEffort {
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)]$State
    )

    try {
        Write-JsonAtomic -Path $StatePath -Value $State
    }
    catch {
        Write-Warning "Plugin deployment succeeded, but PluginManager could not update state: $($_.Exception.Message)"
    }
}

function Wait-ServiceState {
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

function Invoke-WithStoppedService {
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
            Wait-ServiceState -Service $service -Status ([System.ServiceProcess.ServiceControllerStatus]::Stopped)
        }

        & $Mutation

        if ($wasRunning) {
            Start-Service -Name $ServiceName
            $service.Refresh()
            Wait-ServiceState -Service $service -Status ([System.ServiceProcess.ServiceControllerStatus]::Running)
        }
    }
    catch {
        $original = $_
        try {
            $service.Refresh()
            if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
                $service.Refresh()
                Wait-ServiceState -Service $service -Status ([System.ServiceProcess.ServiceControllerStatus]::Stopped)
            }
            & $Rollback
            if ($wasRunning) {
                Start-Service -Name $ServiceName
                $service.Refresh()
                Wait-ServiceState -Service $service -Status ([System.ServiceProcess.ServiceControllerStatus]::Running)
            }
        }
        catch {
            Write-Error "Rollback also failed: $($_.Exception.Message)"
        }
        throw $original
    }
}

function New-PluginBackup {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)]$InventoryItem,
        [string]$ReleaseTag,
        [string]$ManagedId
    )

    $key = if ($ManagedId) { Normalize-PluginKey $ManagedId } else { Normalize-PluginKey $InventoryItem.Name }
    $backupDirectory = Join-Path $Paths.Backups $key
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
    $backupJar = Join-Path $backupDirectory "$timestamp-$($InventoryItem.FileName)"
    Copy-Item -LiteralPath $InventoryItem.Path -Destination $backupJar -Force

    $metadata = [ordered]@{
        pluginName = $InventoryItem.Name
        version = $InventoryItem.Version
        managedId = $ManagedId
        originalFileName = $InventoryItem.FileName
        enabled = [bool]$InventoryItem.Enabled
        releaseTag = $ReleaseTag
        createdUtc = [DateTimeOffset]::UtcNow.ToString("O")
    }
    Write-JsonAtomic -Path "$backupJar.json" -Value $metadata

    return $backupJar
}

function Remove-OldBackups {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$PluginKey,
        [ValidateRange(1, 100)][int]$BackupCount
    )

    $backupDirectory = Join-Path $Paths.Backups (Normalize-PluginKey $PluginKey)
    if (-not (Test-Path -LiteralPath $backupDirectory)) {
        return
    }

    $old = @(Get-ChildItem -LiteralPath $backupDirectory -File -Filter "*.jar" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $BackupCount)

    foreach ($jar in $old) {
        Remove-Item -LiteralPath $jar.FullName -Force
        Remove-Item -LiteralPath "$($jar.FullName).json" -Force -ErrorAction SilentlyContinue
    }
}

function Get-StateRecord {
    param(
        [Parameter(Mandatory)]$State,
        [string]$ManagedId,
        [string]$PluginName
    )

    foreach ($key in @($ManagedId, (Normalize-PluginKey $PluginName))) {
        if ($key -and $State.plugins.ContainsKey($key)) {
            return $State.plugins[$key]
        }
    }
    return $null
}

function Set-StateRecord {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$PluginName,
        [string]$ManagedId,
        [string]$Repository,
        [string]$ReleaseTag,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][bool]$Enabled,
        [string]$Sha256
    )

    $State.plugins[$Key] = [ordered]@{
        pluginName = $PluginName
        managedId = $ManagedId
        repository = $Repository
        releaseTag = $ReleaseTag
        version = $Version
        fileName = $FileName
        enabled = $Enabled
        sha256 = $Sha256
        updatedUtc = [DateTimeOffset]::UtcNow.ToString("O")
    }
}

function Remove-StateRecord {
    param(
        [Parameter(Mandatory)]$State,
        [string]$ManagedId,
        [Parameter(Mandatory)][string]$PluginName
    )

    foreach ($key in @($ManagedId, (Normalize-PluginKey $PluginName))) {
        if ($key -and $State.plugins.ContainsKey($key)) {
            $State.plugins.Remove($key)
        }
    }
}

function Invoke-ManagedInstall {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$ServiceName,
        [string]$Version,
        [ValidateSet("Stable", "Prerelease")][string]$Channel,
        [ValidateRange(1, 100)][int]$BackupCount,
        [switch]$DryRun
    )

    $selectedChannel = if ($PSBoundParameters.ContainsKey("Channel") -and $Channel) { $Channel } elseif ($Entry.defaultChannel) { [string]$Entry.defaultChannel } else { "Stable" }
    Write-Host "==> Resolving $($Entry.pluginName) release"
    $release = Get-GitHubRelease -Repository $Entry.repository -Version $Version -Channel $selectedChannel
    $jarAsset = Resolve-ReleaseAsset -Release $release -Pattern $Entry.assetPattern -Purpose "plugin JAR"

    Ensure-ManagerDirectories -Paths $Paths
    $downloadDirectory = Join-Path $Paths.Downloads ([Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null

    try {
        $downloadedJar = Join-Path $downloadDirectory ([string]$jarAsset.name)
        Write-Host "==> Downloading $($jarAsset.name)"
        Invoke-WebRequest -Uri $jarAsset.browser_download_url -OutFile $downloadedJar -UseBasicParsing

        $expectedHash = Get-ExpectedSha256 -Release $release -JarAsset $jarAsset -ChecksumAssetPattern $Entry.checksumAssetPattern -DownloadDirectory $downloadDirectory
        $actualHash = (Get-FileHash -LiteralPath $downloadedJar -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "SHA-256 verification failed. Expected $expectedHash, got $actualHash."
        }

        $metadata = Get-PluginJarMetadata -Path $downloadedJar
        if (-not $metadata.Name.Equals([string]$Entry.pluginName, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Downloaded JAR declares plugin '$($metadata.Name)', expected '$($Entry.pluginName)'."
        }

        $inventory = Get-InstalledPluginInventory -ServerPath $Paths.Server -Catalog $Catalog
        $existingMatches = @($inventory | Where-Object {
            ($_.ManagedId -and ([string]$_.ManagedId).Equals([string]$Entry.id, [System.StringComparison]::OrdinalIgnoreCase)) -or
            ([string]$_.Name).Equals([string]$Entry.pluginName, [System.StringComparison]::OrdinalIgnoreCase)
        })
        if ($existingMatches.Count -gt 1) {
            throw "Multiple installed JARs match $($Entry.pluginName). Resolve duplicates before continuing."
        }

        $existing = if ($existingMatches.Count -eq 1) { $existingMatches[0] } else { $null }
        $releaseVersion = ([string]$release.tag_name).TrimStart('v')
        if ($existing -and ([string]$existing.Version).Equals($releaseVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "$($Entry.pluginName) $($release.tag_name) is already installed."
            return
        }

        $targetDirectory = if ($existing -and -not $existing.Enabled) { $Paths.Disabled } else { $Paths.Plugins }
        $targetPath = Join-Path $targetDirectory ([string]$Entry.installedFile)

        if ($DryRun) {
            Write-Host "DRY RUN: would install $($release.tag_name) to $targetPath"
            return
        }

        Assert-Administrator
        $state = Get-ManagerState -StatePath $Paths.State
        $stateRecord = if ($existing) { Get-StateRecord -State $state -ManagedId $Entry.id -PluginName $existing.Name } else { $null }
        $backup = if ($existing) { New-PluginBackup -Paths $Paths -InventoryItem $existing -ReleaseTag $stateRecord.releaseTag -ManagedId $Entry.id } else { $null }
        $oldPath = if ($existing) { $existing.Path } else { $null }

        $mutation = {
            if ($oldPath -and (Test-Path -LiteralPath $oldPath)) {
                Remove-Item -LiteralPath $oldPath -Force
            }
            if ((Test-Path -LiteralPath $targetPath) -and (-not $oldPath -or -not $targetPath.Equals($oldPath, [System.StringComparison]::OrdinalIgnoreCase))) {
                throw "Target plugin path already exists: $targetPath"
            }
            Copy-Item -LiteralPath $downloadedJar -Destination $targetPath -Force
        }

        $rollback = {
            if (Test-Path -LiteralPath $targetPath) {
                Remove-Item -LiteralPath $targetPath -Force
            }
            if ($backup -and $oldPath) {
                Copy-Item -LiteralPath $backup -Destination $oldPath -Force
            }
        }

        Write-Host "==> Installing $($Entry.pluginName) $($release.tag_name)"
        Invoke-WithStoppedService -ServiceName $ServiceName -Mutation $mutation -Rollback $rollback

        Set-StateRecord -State $state -Key ([string]$Entry.id) -PluginName $metadata.Name -ManagedId $Entry.id -Repository $Entry.repository -ReleaseTag $release.tag_name -Version $metadata.Version -FileName $Entry.installedFile -Enabled ($targetDirectory -eq $Paths.Plugins) -Sha256 $actualHash
        Save-ManagerStateBestEffort -StatePath $Paths.State -State $state
        Remove-OldBackups -Paths $Paths -PluginKey $Entry.id -BackupCount $BackupCount

        Write-Host "$($Entry.pluginName) $($release.tag_name) installed successfully."
    }
    finally {
        Remove-Item -LiteralPath $downloadDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-LocalInstall {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$ServiceName,
        [ValidateRange(1, 100)][int]$BackupCount,
        [switch]$DryRun
    )

    $source = (Resolve-Path -LiteralPath $SourcePath).Path
    $metadata = Get-PluginJarMetadata -Path $source
    $inventory = Get-InstalledPluginInventory -ServerPath $Paths.Server -Catalog $Catalog
    $matches = @($inventory | Where-Object { ([string]$_.Name).Equals($metadata.Name, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -gt 1) {
        throw "Multiple installed JARs declare plugin $($metadata.Name). Resolve duplicates before continuing."
    }

    $existing = if ($matches.Count -eq 1) { $matches[0] } else { $null }
    $safeName = ($metadata.Name -replace '[<>:"/\\|?*]', '_') + ".jar"
    $targetDirectory = if ($existing -and -not $existing.Enabled) { $Paths.Disabled } else { $Paths.Plugins }
    $targetPath = Join-Path $targetDirectory $safeName
    $actualHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($DryRun) {
        Write-Host "DRY RUN: would install local $($metadata.Name) $($metadata.Version) to $targetPath"
        return
    }

    Assert-Administrator
    Ensure-ManagerDirectories -Paths $Paths
    $state = Get-ManagerState -StatePath $Paths.State
    $managedId = Resolve-ManagedIdForJar -Catalog $Catalog -FileName $safeName -PluginName $metadata.Name
    $stateRecord = if ($existing) { Get-StateRecord -State $state -ManagedId $managedId -PluginName $existing.Name } else { $null }
    $backup = if ($existing) { New-PluginBackup -Paths $Paths -InventoryItem $existing -ReleaseTag $stateRecord.releaseTag -ManagedId $managedId } else { $null }
    $oldPath = if ($existing) { $existing.Path } else { $null }

    $mutation = {
        if ($oldPath -and (Test-Path -LiteralPath $oldPath)) {
            Remove-Item -LiteralPath $oldPath -Force
        }
        if ((Test-Path -LiteralPath $targetPath) -and (-not $oldPath -or -not $targetPath.Equals($oldPath, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Target plugin path already exists: $targetPath"
        }
        Copy-Item -LiteralPath $source -Destination $targetPath -Force
    }

    $rollback = {
        if (Test-Path -LiteralPath $targetPath) {
            Remove-Item -LiteralPath $targetPath -Force
        }
        if ($backup -and $oldPath) {
            Copy-Item -LiteralPath $backup -Destination $oldPath -Force
        }
    }

    Invoke-WithStoppedService -ServiceName $ServiceName -Mutation $mutation -Rollback $rollback

    $key = if ($managedId) { $managedId } else { Normalize-PluginKey $metadata.Name }
    $entry = if ($managedId) { Get-CatalogEntry -Catalog $Catalog -Reference $managedId } else { $null }
    Set-StateRecord -State $state -Key $key -PluginName $metadata.Name -ManagedId $managedId -Repository $entry.repository -ReleaseTag $null -Version $metadata.Version -FileName $safeName -Enabled ($targetDirectory -eq $Paths.Plugins) -Sha256 $actualHash
    Save-ManagerStateBestEffort -StatePath $Paths.State -State $state
    Remove-OldBackups -Paths $Paths -PluginKey $key -BackupCount $BackupCount

    Write-Host "$($metadata.Name) $($metadata.Version) installed successfully from local JAR."
}

function Invoke-RemovePlugin {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$ServiceName,
        [ValidateRange(1, 100)][int]$BackupCount,
        [switch]$DryRun,
        [switch]$Force
    )

    if (-not $Force) {
        throw "Remove requires -Force. Plugin data directories are still preserved."
    }
    if ($DryRun) {
        Write-Host "DRY RUN: would remove $($Item.Path) and preserve its data directory."
        return
    }

    Assert-Administrator
    Ensure-ManagerDirectories -Paths $Paths
    $state = Get-ManagerState -StatePath $Paths.State
    $record = Get-StateRecord -State $state -ManagedId $Item.ManagedId -PluginName $Item.Name
    $backup = New-PluginBackup -Paths $Paths -InventoryItem $Item -ReleaseTag $record.releaseTag -ManagedId $Item.ManagedId
    $oldPath = $Item.Path

    Invoke-WithStoppedService -ServiceName $ServiceName -Mutation {
        Remove-Item -LiteralPath $oldPath -Force
    } -Rollback {
        if (-not (Test-Path -LiteralPath $oldPath)) {
            Copy-Item -LiteralPath $backup -Destination $oldPath -Force
        }
    }

    Remove-StateRecord -State $state -ManagedId $Item.ManagedId -PluginName $Item.Name
    Save-ManagerStateBestEffort -StatePath $Paths.State -State $state
    Remove-OldBackups -Paths $Paths -PluginKey $(if ($Item.ManagedId) { $Item.ManagedId } else { $Item.Name }) -BackupCount $BackupCount
    Write-Host "$($Item.Name) removed. Plugin data was preserved."
}

function Invoke-SetPluginEnabled {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][bool]$Enabled,
        [switch]$DryRun
    )

    if ($Item.Enabled -eq $Enabled) {
        Write-Host "$($Item.Name) is already $(if ($Enabled) { 'enabled' } else { 'disabled' })."
        return
    }

    $targetDirectory = if ($Enabled) { $Paths.Plugins } else { $Paths.Disabled }
    Ensure-ManagerDirectories -Paths $Paths
    $targetPath = Join-Path $targetDirectory $Item.FileName

    if (Test-Path -LiteralPath $targetPath) {
        throw "Cannot change plugin state because target JAR already exists: $targetPath"
    }

    if ($DryRun) {
        Write-Host "DRY RUN: would move $($Item.Path) to $targetPath"
        return
    }

    Assert-Administrator
    $oldPath = $Item.Path
    Invoke-WithStoppedService -ServiceName $ServiceName -Mutation {
        Move-Item -LiteralPath $oldPath -Destination $targetPath -Force
    } -Rollback {
        if (Test-Path -LiteralPath $targetPath) {
            Move-Item -LiteralPath $targetPath -Destination $oldPath -Force
        }
    }

    $state = Get-ManagerState -StatePath $Paths.State
    $record = Get-StateRecord -State $state -ManagedId $Item.ManagedId -PluginName $Item.Name
    if ($record) {
        $record.enabled = $Enabled
        $record.fileName = $Item.FileName
        $record.updatedUtc = [DateTimeOffset]::UtcNow.ToString("O")
        Save-ManagerStateBestEffort -StatePath $Paths.State -State $state
    }

    Write-Host "$($Item.Name) $(if ($Enabled) { 'enabled' } else { 'disabled' }) successfully."
}

function Invoke-RollbackPlugin {
    param(
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$ServiceName,
        [ValidateRange(1, 100)][int]$BackupCount,
        [switch]$DryRun
    )

    $inventory = Get-InstalledPluginInventory -ServerPath $Paths.Server -Catalog $Catalog
    $current = Resolve-InstalledPlugin -Reference $Reference -Inventory $inventory
    $entry = Get-CatalogEntry -Catalog $Catalog -Reference $Reference
    $key = if ($current -and $current.ManagedId) { $current.ManagedId } elseif ($entry) { $entry.id } elseif ($current) { Normalize-PluginKey $current.Name } else { Normalize-PluginKey $Reference }
    $backupDirectory = Join-Path $Paths.Backups (Normalize-PluginKey $key)

    if (-not (Test-Path -LiteralPath $backupDirectory)) {
        throw "No backups exist for $Reference."
    }

    $backup = Get-ChildItem -LiteralPath $backupDirectory -File -Filter "*.jar" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $backup) {
        throw "No backups exist for $Reference."
    }

    $metadataPath = "$($backup.FullName).json"
    if (-not (Test-Path -LiteralPath $metadataPath)) {
        throw "Backup metadata is missing: $metadataPath"
    }
    $backupMetadata = Read-JsonHashtable -Path $metadataPath
    $targetDirectory = if ([bool]$backupMetadata.enabled) { $Paths.Plugins } else { $Paths.Disabled }
    $targetPath = Join-Path $targetDirectory ([string]$backupMetadata.originalFileName)

    if ($DryRun) {
        Write-Host "DRY RUN: would restore $($backup.FullName) to $targetPath"
        return
    }

    Assert-Administrator
    Ensure-ManagerDirectories -Paths $Paths
    $currentBackup = if ($current) {
        $state = Get-ManagerState -StatePath $Paths.State
        $currentRecord = Get-StateRecord -State $state -ManagedId $current.ManagedId -PluginName $current.Name
        New-PluginBackup -Paths $Paths -InventoryItem $current -ReleaseTag $currentRecord.releaseTag -ManagedId $current.ManagedId
    } else { $null }
    $currentPath = if ($current) { $current.Path } else { $null }

    Invoke-WithStoppedService -ServiceName $ServiceName -Mutation {
        if ($currentPath -and (Test-Path -LiteralPath $currentPath)) {
            Remove-Item -LiteralPath $currentPath -Force
        }
        Copy-Item -LiteralPath $backup.FullName -Destination $targetPath -Force
    } -Rollback {
        if (Test-Path -LiteralPath $targetPath) {
            Remove-Item -LiteralPath $targetPath -Force
        }
        if ($currentBackup -and $currentPath) {
            Copy-Item -LiteralPath $currentBackup -Destination $currentPath -Force
        }
    }

    $restoredMetadata = Get-PluginJarMetadata -Path $targetPath
    $state = Get-ManagerState -StatePath $Paths.State
    $managedId = [string]$backupMetadata.managedId
    $catalogEntry = if ($managedId) { Get-CatalogEntry -Catalog $Catalog -Reference $managedId } else { $null }
    $stateKey = if ($managedId) { $managedId } else { Normalize-PluginKey $restoredMetadata.Name }
    $hash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-StateRecord -State $state -Key $stateKey -PluginName $restoredMetadata.Name -ManagedId $managedId -Repository $catalogEntry.repository -ReleaseTag $backupMetadata.releaseTag -Version $restoredMetadata.Version -FileName ([System.IO.Path]::GetFileName($targetPath)) -Enabled ([bool]$backupMetadata.enabled) -Sha256 $hash
    Save-ManagerStateBestEffort -StatePath $Paths.State -State $state
    Remove-OldBackups -Paths $Paths -PluginKey $key -BackupCount $BackupCount

    Write-Host "$($restoredMetadata.Name) rolled back to version $($restoredMetadata.Version)."
}

function Get-PluginStatusObject {
    param(
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$Paths,
        [ValidateSet("Stable", "Prerelease")][string]$Channel
    )

    $inventory = Get-InstalledPluginInventory -ServerPath $Paths.Server -Catalog $Catalog
    $installed = Resolve-InstalledPlugin -Reference $Reference -Inventory $inventory
    $entry = Get-CatalogEntry -Catalog $Catalog -Reference $Reference

    $releaseTag = $null
    $releaseError = $null
    if ($entry) {
        $selectedChannel = if ($Channel) { $Channel } elseif ($entry.defaultChannel) { [string]$entry.defaultChannel } else { "Stable" }
        try {
            $releaseTag = (Get-GitHubRelease -Repository $entry.repository -Channel $selectedChannel).tag_name
        }
        catch {
            $releaseError = $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        Reference = $Reference
        Name = if ($installed) { $installed.Name } elseif ($entry) { $entry.pluginName } else { $Reference }
        Installed = ($null -ne $installed)
        Enabled = if ($installed) { $installed.Enabled } else { $null }
        InstalledVersion = if ($installed) { $installed.Version } else { $null }
        FileName = if ($installed) { $installed.FileName } else { $null }
        Managed = ($null -ne $entry)
        ManagedId = if ($entry) { $entry.id } else { $installed.ManagedId }
        Repository = if ($entry) { $entry.repository } else { $null }
        LatestRelease = $releaseTag
        ReleaseError = $releaseError
    }
}

function Invoke-PluginManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("list", "catalog", "status", "install", "update", "install-file", "remove", "disable", "enable", "rollback")][string]$Command,
        [string]$Plugin,
        [string]$Path,
        [string]$Version,
        [ValidateSet("Stable", "Prerelease")][string]$Channel,
        [Parameter(Mandatory)][string]$ServerPath,
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][string]$CatalogPath,
        [ValidateRange(1, 100)][int]$BackupCount = 10,
        [switch]$DryRun,
        [switch]$Force
    )

    $catalog = Get-PluginCatalog -CatalogPath $CatalogPath
    $paths = Get-ManagerPaths -ServerPath $ServerPath

    switch ($Command) {
        "catalog" {
            return @($catalog.plugins | ForEach-Object {
                [pscustomobject]@{
                    Id = $_.id
                    Name = $_.pluginName
                    Repository = $_.repository
                    DefaultChannel = if ($_.defaultChannel) { $_.defaultChannel } else { "Stable" }
                }
            })
        }
        "list" {
            return Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $catalog
        }
        "status" {
            if (-not $Plugin) { throw "status requires a plugin reference." }
            return Get-PluginStatusObject -Reference $Plugin -Catalog $catalog -Paths $paths -Channel $Channel
        }
        "install" {
            if (-not $Plugin) { throw "install requires a managed plugin id or name." }
            $entry = Get-CatalogEntry -Catalog $catalog -Reference $Plugin
            if (-not $entry) { throw "Plugin '$Plugin' is not in the managed catalog. Use install-file for a local JAR." }
            $parameters = @{
                Entry = $entry
                Catalog = $catalog
                Paths = $paths
                ServiceName = $ServiceName
                Version = $Version
                BackupCount = $BackupCount
                DryRun = $DryRun
            }
            if ($Channel) { $parameters.Channel = $Channel }
            Invoke-ManagedInstall @parameters
            return
        }
        "update" {
            if (-not $Plugin) { throw "update requires a managed plugin id or name." }
            $entry = Get-CatalogEntry -Catalog $catalog -Reference $Plugin
            if (-not $entry) { throw "Plugin '$Plugin' is not in the managed catalog and cannot be updated automatically." }
            $inventory = Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $catalog
            if (-not (Resolve-InstalledPlugin -Reference $Plugin -Inventory $inventory)) {
                throw "Plugin '$Plugin' is not installed. Use install first."
            }
            $parameters = @{
                Entry = $entry
                Catalog = $catalog
                Paths = $paths
                ServiceName = $ServiceName
                Version = $Version
                BackupCount = $BackupCount
                DryRun = $DryRun
            }
            if ($Channel) { $parameters.Channel = $Channel }
            Invoke-ManagedInstall @parameters
            return
        }
        "install-file" {
            if (-not $Path) { throw "install-file requires -Path <jar>." }
            Invoke-LocalInstall -SourcePath $Path -Catalog $catalog -Paths $paths -ServiceName $ServiceName -BackupCount $BackupCount -DryRun:$DryRun
            return
        }
        "remove" {
            if (-not $Plugin) { throw "remove requires a plugin reference." }
            $inventory = Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $catalog
            $item = Resolve-InstalledPlugin -Reference $Plugin -Inventory $inventory
            if (-not $item) { throw "Plugin '$Plugin' is not installed or disabled." }
            Invoke-RemovePlugin -Item $item -Paths $paths -ServiceName $ServiceName -BackupCount $BackupCount -DryRun:$DryRun -Force:$Force
            return
        }
        "disable" {
            if (-not $Plugin) { throw "disable requires a plugin reference." }
            $inventory = Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $catalog
            $item = Resolve-InstalledPlugin -Reference $Plugin -Inventory $inventory
            if (-not $item) { throw "Plugin '$Plugin' is not installed." }
            Invoke-SetPluginEnabled -Item $item -Paths $paths -ServiceName $ServiceName -Enabled $false -DryRun:$DryRun
            return
        }
        "enable" {
            if (-not $Plugin) { throw "enable requires a plugin reference." }
            $inventory = Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $catalog
            $item = Resolve-InstalledPlugin -Reference $Plugin -Inventory $inventory
            if (-not $item) { throw "Plugin '$Plugin' is not installed." }
            Invoke-SetPluginEnabled -Item $item -Paths $paths -ServiceName $ServiceName -Enabled $true -DryRun:$DryRun
            return
        }
        "rollback" {
            if (-not $Plugin) { throw "rollback requires a plugin reference." }
            Invoke-RollbackPlugin -Reference $Plugin -Catalog $catalog -Paths $paths -ServiceName $ServiceName -BackupCount $BackupCount -DryRun:$DryRun
            return
        }
    }
}

Export-ModuleMember -Function @(
    "Invoke-PluginManager",
    "Get-PluginCatalog",
    "Get-CatalogEntry",
    "Get-PluginJarMetadata",
    "Get-InstalledPluginInventory",
    "Get-GitHubRelease",
    "Resolve-ReleaseAsset",
    "Get-ExpectedSha256"
)
