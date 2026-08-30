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

function Get-OptionalValue {
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

function ConvertTo-PluginManagerHashtable {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = ConvertTo-PluginManagerHashtable $Value[$key]
        }
        return $result
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-PluginManagerHashtable $property.Value
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(ConvertTo-PluginManagerHashtable $item)
        }
        return $items
    }
    return $Value
}

function Read-JsonHashtable {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return ConvertTo-PluginManagerHashtable $parsed
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
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-PluginCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CatalogPath)

    if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
        throw "Plugin catalog does not exist: $CatalogPath"
    }

    $catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json
    if ($catalog.schemaVersion -ne 1) {
        throw "Unsupported plugin catalog schema version: $($catalog.schemaVersion)"
    }

    $seen = @{}
    foreach ($entry in @($catalog.plugins)) {
        foreach ($required in @("id", "pluginName", "repository", "assetPattern", "installedFile")) {
            if (-not (Get-OptionalValue -Object $entry -Name $required)) {
                throw "Catalog entry is missing required field '$required'."
            }
        }

        $id = Normalize-PluginKey ([string]$entry.id)
        if ($seen.ContainsKey($id)) {
            throw "Duplicate plugin catalog id: $id"
        }
        $seen[$id] = $true

        $channel = Get-OptionalValue -Object $entry -Name "defaultChannel" -Default "Stable"
        if ($channel -notin @("Stable", "Prerelease")) {
            throw "Invalid default channel for $($entry.id): $channel"
        }

        [void][regex]::new([string]$entry.assetPattern)
        $checksumPattern = Get-OptionalValue -Object $entry -Name "checksumAssetPattern"
        if ($checksumPattern) {
            [void][regex]::new([string]$checksumPattern)
        }
        foreach ($pattern in @(Get-OptionalValue -Object $entry -Name "installedFilePatterns" -Default @())) {
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

    $key = Normalize-PluginKey $Reference
    $matches = @($Catalog.plugins | Where-Object {
        (Normalize-PluginKey ([string]$_.id)) -eq $key -or
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

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $archive = [System.IO.Compression.ZipFile]::OpenRead($resolved)
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
            $text = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $nameMatch = [regex]::Match($text, '(?m)^\s*name\s*:\s*["'']?([^"''#\r\n]+)')
        $versionMatch = [regex]::Match($text, '(?m)^\s*version\s*:\s*["'']?([^"''#\r\n]+)')
        if (-not $nameMatch.Success) {
            throw "Plugin metadata does not contain a name: $Path"
        }

        return [pscustomobject]@{
            Name = $nameMatch.Groups[1].Value.Trim()
            Version = if ($versionMatch.Success) { $versionMatch.Groups[1].Value.Trim() } else { "unknown" }
            MetadataFile = $entry.FullName
            Path = $resolved
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Test-CatalogFileMatch {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$FileName
    )

    if ($FileName.Equals([string]$Entry.installedFile, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    foreach ($pattern in @(Get-OptionalValue -Object $Entry -Name "installedFilePatterns" -Default @())) {
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
        (Test-CatalogFileMatch -Entry $_ -FileName $FileName)
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

    $items = @()
    $sources = @(
        [pscustomobject]@{ Path = Join-Path $ServerPath "plugins"; Enabled = $true },
        [pscustomobject]@{ Path = Join-Path $ServerPath "plugins-disabled"; Enabled = $false }
    )

    foreach ($source in $sources) {
        if (-not (Test-Path -LiteralPath $source.Path -PathType Container)) {
            continue
        }

        foreach ($jar in Get-ChildItem -LiteralPath $source.Path -File -Filter "*.jar") {
            try {
                $metadata = Get-PluginJarMetadata -Path $jar.FullName
                $name = $metadata.Name
                $version = $metadata.Version
                $metadataError = $null
            }
            catch {
                $name = [System.IO.Path]::GetFileNameWithoutExtension($jar.Name)
                $version = "unknown"
                $metadataError = $_.Exception.Message
            }

            $managedId = Resolve-ManagedIdForJar -Catalog $Catalog -FileName $jar.Name -PluginName $name
            $items += [pscustomobject]@{
                Name = $name
                Version = $version
                Enabled = [bool]$source.Enabled
                Managed = ($null -ne $managedId)
                ManagedId = $managedId
                FileName = $jar.Name
                Path = $jar.FullName
                MetadataError = $metadataError
            }
        }
    }

    return $items
}

function Resolve-InstalledPlugin {
    param(
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)][object[]]$Inventory
    )

    $key = Normalize-PluginKey $Reference
    $matches = @($Inventory | Where-Object {
        ($_.ManagedId -and (Normalize-PluginKey ([string]$_.ManagedId)) -eq $key) -or
        ([string]$_.Name).Equals($Reference, [System.StringComparison]::OrdinalIgnoreCase) -or
        ([string]$_.FileName).Equals($Reference, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Normalize-PluginKey ([System.IO.Path]::GetFileNameWithoutExtension([string]$_.FileName))) -eq $key
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

function Select-GitHubRelease {
    param(
        [Parameter(Mandatory)]$Releases,
        [ValidateSet("Stable", "Prerelease")][string]$Channel = "Stable"
    )

    foreach ($release in $Releases) {
        $isDraft = [bool](Get-OptionalValue -Object $release -Name "draft" -Default $false)
        if ($isDraft) {
            continue
        }

        $isPrerelease = [bool](Get-OptionalValue -Object $release -Name "prerelease" -Default $false)
        if ($Channel -eq "Prerelease" -and $isPrerelease) {
            return $release
        }
        if ($Channel -eq "Stable" -and -not $isPrerelease) {
            return $release
        }
    }

    return $null
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
        $encoded = [System.Uri]::EscapeDataString($tag)
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/tags/$encoded" -Headers $script:GitHubHeaders -Method Get
    }

    $response = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases?per_page=100" -Headers $script:GitHubHeaders -Method Get
    $selected = Select-GitHubRelease -Releases $response -Channel $Channel

    if (-not $selected) {
        throw "No $Channel release is available for $Repository."
    }
    return $selected
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
        $checksumAssets = @($Release.assets | Where-Object { [string]$_.name -match $ChecksumAssetPattern })
        if ($checksumAssets.Count -gt 1) {
            throw "Release $($Release.tag_name) contains multiple checksum assets matching '$ChecksumAssetPattern'."
        }
        if ($checksumAssets.Count -eq 1) {
            $checksumPath = Join-Path $DownloadDirectory ([string]$checksumAssets[0].name)
            Invoke-WebRequest -Uri $checksumAssets[0].browser_download_url -OutFile $checksumPath -UseBasicParsing
            $hash = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split "\s+")[0].ToLowerInvariant()
            if ($hash -notmatch "^[0-9a-f]{64}$") {
                throw "Checksum asset contains an invalid SHA-256 value."
            }
            return $hash
        }
    }

    $digest = [string](Get-OptionalValue -Object $JarAsset -Name "digest" -Default "")
    if ($digest -match '^sha256:([0-9a-fA-F]{64})$') {
        return $Matches[1].ToLowerInvariant()
    }

    throw "Release $($Release.tag_name) does not provide a usable SHA-256 checksum or GitHub asset digest."
}

function Get-ManagerPaths {
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

function Ensure-MutationPaths {
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

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this command from PowerShell as Administrator."
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

function Get-ManagerState {
    param([Parameter(Mandatory)][string]$Path)

    $state = Read-JsonHashtable -Path $Path
    if ($null -eq $state) {
        return @{ schemaVersion = 1; plugins = @{} }
    }
    if ($state.schemaVersion -ne 1) {
        throw "Unsupported PluginManager state schema version: $($state.schemaVersion)"
    }
    if (-not $state.ContainsKey("plugins")) {
        $state.plugins = @{}
    }
    return $state
}

function Save-ManagerStateBestEffort {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )

    try {
        Write-JsonAtomic -Path $Path -Value $State
    }
    catch {
        Write-Warning "Plugin operation succeeded, but PluginManager state could not be updated: $($_.Exception.Message)"
    }
}

function Get-StateRecord {
    param(
        [Parameter(Mandatory)]$State,
        [string]$ManagedId,
        [Parameter(Mandatory)][string]$PluginName
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
            [void]$State.plugins.Remove($key)
        }
    }
}

function New-PluginBackup {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)]$Item,
        [string]$ReleaseTag,
        [string]$ManagedId
    )

    $key = if ($ManagedId) { Normalize-PluginKey $ManagedId } else { Normalize-PluginKey $Item.Name }
    $directory = Join-Path $Paths.Backups $key
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
    $backupPath = Join-Path $directory "$timestamp-$($Item.FileName)"
    Copy-Item -LiteralPath $Item.Path -Destination $backupPath -Force

    Write-JsonAtomic -Path "$backupPath.json" -Value ([ordered]@{
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

function Remove-OldBackups {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$PluginKey,
        [ValidateRange(1, 100)][int]$BackupCount
    )

    $directory = Join-Path $Paths.Backups (Normalize-PluginKey $PluginKey)
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

function Invoke-ManagedInstall {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$ServiceName,
        [string]$Version,
        [string]$Channel,
        [ValidateRange(1, 100)][int]$BackupCount,
        [switch]$DryRun
    )

    Ensure-MutationPaths -Paths $Paths

    $selectedChannel = if ($Channel) { $Channel } else { [string](Get-OptionalValue -Object $Entry -Name "defaultChannel" -Default "Stable") }
    $release = Get-GitHubRelease -Repository $Entry.repository -Version $Version -Channel $selectedChannel
    $jarAsset = Resolve-ReleaseAsset -Release $release -Pattern $Entry.assetPattern -Purpose "plugin JAR"

    $downloadDirectory = Join-Path $Paths.Downloads ([Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $downloadDirectory -Force | Out-Null

    try {
        $downloadedJar = Join-Path $downloadDirectory ([string]$jarAsset.name)
        Invoke-WebRequest -Uri $jarAsset.browser_download_url -OutFile $downloadedJar -UseBasicParsing

        $checksumPattern = Get-OptionalValue -Object $Entry -Name "checksumAssetPattern"
        $expectedHash = Get-ExpectedSha256 -Release $release -JarAsset $jarAsset -ChecksumAssetPattern $checksumPattern -DownloadDirectory $downloadDirectory
        $actualHash = (Get-FileHash -LiteralPath $downloadedJar -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "SHA-256 verification failed. Expected $expectedHash, got $actualHash."
        }

        $metadata = Get-PluginJarMetadata -Path $downloadedJar
        if (-not $metadata.Name.Equals([string]$Entry.pluginName, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Downloaded JAR declares plugin '$($metadata.Name)', expected '$($Entry.pluginName)'."
        }

        $inventory = Get-InstalledPluginInventory -ServerPath $Paths.Server -Catalog $Catalog
        $matches = @($inventory | Where-Object {
            ($_.ManagedId -and ([string]$_.ManagedId).Equals([string]$Entry.id, [System.StringComparison]::OrdinalIgnoreCase)) -or
            ([string]$_.Name).Equals([string]$Entry.pluginName, [System.StringComparison]::OrdinalIgnoreCase)
        })
        if ($matches.Count -gt 1) {
            throw "Multiple installed JARs match $($Entry.pluginName). Resolve duplicates before continuing."
        }

        $existing = if ($matches.Count -eq 1) { $matches[0] } else { $null }
        $releaseVersion = ([string]$release.tag_name) -replace '^v', ''
        if ($existing -and ([string]$existing.Version).Equals($releaseVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Action = "none"
                Name = $metadata.Name
                Version = $metadata.Version
                ReleaseTag = $release.tag_name
                Enabled = $existing.Enabled
                Path = $existing.Path
                Changed = $false
            }
        }

        $targetDirectory = if ($existing -and -not $existing.Enabled) { $Paths.Disabled } else { $Paths.Plugins }
        $targetPath = Join-Path $targetDirectory ([string]$Entry.installedFile)

        if ($DryRun) {
            return [pscustomobject]@{
                Action = if ($existing) { "update" } else { "install" }
                Name = $metadata.Name
                Version = $metadata.Version
                ReleaseTag = $release.tag_name
                Enabled = ($targetDirectory -eq $Paths.Plugins)
                Path = $targetPath
                Changed = $false
                DryRun = $true
            }
        }

        Assert-Administrator
        $state = Get-ManagerState -Path $Paths.State
        $record = if ($existing) { Get-StateRecord -State $state -ManagedId $Entry.id -PluginName $existing.Name } else { $null }
        $previousRelease = Get-OptionalValue -Object $record -Name "releaseTag"
        $backup = if ($existing) { New-PluginBackup -Paths $Paths -Item $existing -ReleaseTag $previousRelease -ManagedId $Entry.id } else { $null }
        $oldPath = if ($existing) { $existing.Path } else { $null }

        Invoke-WithStoppedService -ServiceName $ServiceName -Mutation {
            if ($oldPath -and (Test-Path -LiteralPath $oldPath)) {
                Remove-Item -LiteralPath $oldPath -Force
            }
            if ((Test-Path -LiteralPath $targetPath) -and (-not $oldPath -or -not $targetPath.Equals($oldPath, [System.StringComparison]::OrdinalIgnoreCase))) {
                throw "Target plugin path already exists: $targetPath"
            }
            Copy-Item -LiteralPath $downloadedJar -Destination $targetPath -Force
        } -Rollback {
            if (Test-Path -LiteralPath $targetPath) {
                Remove-Item -LiteralPath $targetPath -Force
            }
            if ($backup -and $oldPath) {
                Copy-Item -LiteralPath $backup -Destination $oldPath -Force
            }
        }

        Set-StateRecord -State $state -Key ([string]$Entry.id) -PluginName $metadata.Name -ManagedId $Entry.id -Repository $Entry.repository -ReleaseTag $release.tag_name -Version $metadata.Version -FileName $Entry.installedFile -Enabled ($targetDirectory -eq $Paths.Plugins) -Sha256 $actualHash
        Save-ManagerStateBestEffort -Path $Paths.State -State $state
        Remove-OldBackups -Paths $Paths -PluginKey $Entry.id -BackupCount $BackupCount

        return [pscustomobject]@{
            Action = if ($existing) { "update" } else { "install" }
            Name = $metadata.Name
            Version = $metadata.Version
            ReleaseTag = $release.tag_name
            Enabled = ($targetDirectory -eq $Paths.Plugins)
            Path = $targetPath
            Changed = $true
        }
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

    Ensure-MutationPaths -Paths $Paths
    $source = (Resolve-Path -LiteralPath $SourcePath).Path
    $metadata = Get-PluginJarMetadata -Path $source
    $inventory = Get-InstalledPluginInventory -ServerPath $Paths.Server -Catalog $Catalog
    $matches = @($inventory | Where-Object { ([string]$_.Name).Equals($metadata.Name, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($matches.Count -gt 1) {
        throw "Multiple installed JARs declare plugin $($metadata.Name). Resolve duplicates before continuing."
    }

    $existing = if ($matches.Count -eq 1) { $matches[0] } else { $null }
    if ($existing -and $source.Equals([string]$existing.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            Action = "none"
            Name = $metadata.Name
            Version = $metadata.Version
            Enabled = $existing.Enabled
            Path = $existing.Path
            Changed = $false
        }
    }

    $safeName = ($metadata.Name -replace '[<>:"/\\|?*]', '_') + ".jar"
    $targetDirectory = if ($existing -and -not $existing.Enabled) { $Paths.Disabled } else { $Paths.Plugins }
    $targetPath = Join-Path $targetDirectory $safeName
    $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($DryRun) {
        return [pscustomobject]@{
            Action = if ($existing) { "update-local" } else { "install-local" }
            Name = $metadata.Name
            Version = $metadata.Version
            Enabled = ($targetDirectory -eq $Paths.Plugins)
            Path = $targetPath
            Changed = $false
            DryRun = $true
        }
    }

    Assert-Administrator
    $state = Get-ManagerState -Path $Paths.State
    $managedId = Resolve-ManagedIdForJar -Catalog $Catalog -FileName $safeName -PluginName $metadata.Name
    $record = if ($existing) { Get-StateRecord -State $state -ManagedId $managedId -PluginName $existing.Name } else { $null }
    $previousRelease = Get-OptionalValue -Object $record -Name "releaseTag"
    $backup = if ($existing) { New-PluginBackup -Paths $Paths -Item $existing -ReleaseTag $previousRelease -ManagedId $managedId } else { $null }
    $oldPath = if ($existing) { $existing.Path } else { $null }

    Invoke-WithStoppedService -ServiceName $ServiceName -Mutation {
        if ($oldPath -and (Test-Path -LiteralPath $oldPath)) {
            Remove-Item -LiteralPath $oldPath -Force
        }
        if ((Test-Path -LiteralPath $targetPath) -and (-not $oldPath -or -not $targetPath.Equals($oldPath, [System.StringComparison]::OrdinalIgnoreCase))) {
            throw "Target plugin path already exists: $targetPath"
        }
        Copy-Item -LiteralPath $source -Destination $targetPath -Force
    } -Rollback {
        if (Test-Path -LiteralPath $targetPath) {
            Remove-Item -LiteralPath $targetPath -Force
        }
        if ($backup -and $oldPath) {
            Copy-Item -LiteralPath $backup -Destination $oldPath -Force
        }
    }

    $catalogEntry = if ($managedId) { Get-CatalogEntry -Catalog $Catalog -Reference $managedId } else { $null }
    $repository = Get-OptionalValue -Object $catalogEntry -Name "repository"
    $key = if ($managedId) { $managedId } else { Normalize-PluginKey $metadata.Name }
    Set-StateRecord -State $state -Key $key -PluginName $metadata.Name -ManagedId $managedId -Repository $repository -ReleaseTag $null -Version $metadata.Version -FileName $safeName -Enabled ($targetDirectory -eq $Paths.Plugins) -Sha256 $hash
    Save-ManagerStateBestEffort -Path $Paths.State -State $state
    Remove-OldBackups -Paths $Paths -PluginKey $key -BackupCount $BackupCount

    return [pscustomobject]@{
        Action = if ($existing) { "update-local" } else { "install-local" }
        Name = $metadata.Name
        Version = $metadata.Version
        Enabled = ($targetDirectory -eq $Paths.Plugins)
        Path = $targetPath
        Changed = $true
    }
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
        return [pscustomobject]@{ Action = "remove"; Name = $Item.Name; Path = $Item.Path; Changed = $false; DryRun = $true }
    }

    Ensure-MutationPaths -Paths $Paths
    Assert-Administrator
    $state = Get-ManagerState -Path $Paths.State
    $record = Get-StateRecord -State $state -ManagedId $Item.ManagedId -PluginName $Item.Name
    $backup = New-PluginBackup -Paths $Paths -Item $Item -ReleaseTag (Get-OptionalValue -Object $record -Name "releaseTag") -ManagedId $Item.ManagedId
    $oldPath = $Item.Path

    Invoke-WithStoppedService -ServiceName $ServiceName -Mutation {
        Remove-Item -LiteralPath $oldPath -Force
    } -Rollback {
        if (-not (Test-Path -LiteralPath $oldPath)) {
            Copy-Item -LiteralPath $backup -Destination $oldPath -Force
        }
    }

    Remove-StateRecord -State $state -ManagedId $Item.ManagedId -PluginName $Item.Name
    Save-ManagerStateBestEffort -Path $Paths.State -State $state
    $key = if ($Item.ManagedId) { $Item.ManagedId } else { $Item.Name }
    Remove-OldBackups -Paths $Paths -PluginKey $key -BackupCount $BackupCount

    return [pscustomobject]@{ Action = "remove"; Name = $Item.Name; Path = $oldPath; Changed = $true }
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
        return [pscustomobject]@{ Action = "none"; Name = $Item.Name; Enabled = $Enabled; Path = $Item.Path; Changed = $false }
    }

    Ensure-MutationPaths -Paths $Paths
    $targetDirectory = if ($Enabled) { $Paths.Plugins } else { $Paths.Disabled }
    $targetPath = Join-Path $targetDirectory $Item.FileName
    if (Test-Path -LiteralPath $targetPath) {
        throw "Cannot change plugin state because target JAR already exists: $targetPath"
    }

    if ($DryRun) {
        return [pscustomobject]@{ Action = if ($Enabled) { "enable" } else { "disable" }; Name = $Item.Name; Enabled = $Enabled; Path = $targetPath; Changed = $false; DryRun = $true }
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

    $state = Get-ManagerState -Path $Paths.State
    $record = Get-StateRecord -State $state -ManagedId $Item.ManagedId -PluginName $Item.Name
    if ($record) {
        $record.enabled = $Enabled
        $record.fileName = $Item.FileName
        $record.updatedUtc = [DateTimeOffset]::UtcNow.ToString("O")
        Save-ManagerStateBestEffort -Path $Paths.State -State $state
    }

    return [pscustomobject]@{ Action = if ($Enabled) { "enable" } else { "disable" }; Name = $Item.Name; Enabled = $Enabled; Path = $targetPath; Changed = $true }
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

    Ensure-MutationPaths -Paths $Paths
    $inventory = Get-InstalledPluginInventory -ServerPath $Paths.Server -Catalog $Catalog
    $current = Resolve-InstalledPlugin -Reference $Reference -Inventory $inventory
    $entry = Get-CatalogEntry -Catalog $Catalog -Reference $Reference
    $key = if ($current -and $current.ManagedId) { $current.ManagedId } elseif ($entry) { $entry.id } elseif ($current) { Normalize-PluginKey $current.Name } else { Normalize-PluginKey $Reference }
    $directory = Join-Path $Paths.Backups (Normalize-PluginKey $key)

    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "No backups exist for $Reference."
    }

    $backup = Get-ChildItem -LiteralPath $directory -File -Filter "*.jar" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $backup) {
        throw "No backups exist for $Reference."
    }

    $backupMetadata = Read-JsonHashtable -Path "$($backup.FullName).json"
    if ($null -eq $backupMetadata) {
        throw "Backup metadata is missing for $($backup.FullName)."
    }

    $targetDirectory = if ([bool]$backupMetadata.enabled) { $Paths.Plugins } else { $Paths.Disabled }
    $targetPath = Join-Path $targetDirectory ([string]$backupMetadata.originalFileName)

    if ($DryRun) {
        return [pscustomobject]@{ Action = "rollback"; Name = $backupMetadata.pluginName; Version = $backupMetadata.version; Path = $targetPath; Changed = $false; DryRun = $true }
    }

    Assert-Administrator
    $state = Get-ManagerState -Path $Paths.State
    $currentRecord = if ($current) { Get-StateRecord -State $state -ManagedId $current.ManagedId -PluginName $current.Name } else { $null }
    $currentBackup = if ($current) { New-PluginBackup -Paths $Paths -Item $current -ReleaseTag (Get-OptionalValue -Object $currentRecord -Name "releaseTag") -ManagedId $current.ManagedId } else { $null }
    $currentPath = if ($current) { $current.Path } else { $null }

    Invoke-WithStoppedService -ServiceName $ServiceName -Mutation {
        if ($currentPath -and (Test-Path -LiteralPath $currentPath)) {
            Remove-Item -LiteralPath $currentPath -Force
        }
        if (Test-Path -LiteralPath $targetPath) {
            throw "Rollback target already exists: $targetPath"
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

    $restored = Get-PluginJarMetadata -Path $targetPath
    $managedId = [string](Get-OptionalValue -Object $backupMetadata -Name "managedId" -Default "")
    $catalogEntry = if ($managedId) { Get-CatalogEntry -Catalog $Catalog -Reference $managedId } else { $null }
    $repository = Get-OptionalValue -Object $catalogEntry -Name "repository"
    $stateKey = if ($managedId) { $managedId } else { Normalize-PluginKey $restored.Name }
    $hash = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-StateRecord -State $state -Key $stateKey -PluginName $restored.Name -ManagedId $managedId -Repository $repository -ReleaseTag (Get-OptionalValue -Object $backupMetadata -Name "releaseTag") -Version $restored.Version -FileName ([System.IO.Path]::GetFileName($targetPath)) -Enabled ([bool]$backupMetadata.enabled) -Sha256 $hash
    Save-ManagerStateBestEffort -Path $Paths.State -State $state
    Remove-OldBackups -Paths $Paths -PluginKey $key -BackupCount $BackupCount

    return [pscustomobject]@{ Action = "rollback"; Name = $restored.Name; Version = $restored.Version; Path = $targetPath; Changed = $true }
}

function Get-PluginStatusObject {
    param(
        [Parameter(Mandatory)][string]$Reference,
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$Paths,
        [string]$Channel
    )

    $inventory = Get-InstalledPluginInventory -ServerPath $Paths.Server -Catalog $Catalog
    $installed = Resolve-InstalledPlugin -Reference $Reference -Inventory $inventory
    $entry = Get-CatalogEntry -Catalog $Catalog -Reference $Reference

    $latest = $null
    $releaseError = $null
    if ($entry) {
        $selectedChannel = if ($Channel) { $Channel } else { [string](Get-OptionalValue -Object $entry -Name "defaultChannel" -Default "Stable") }
        try {
            $latest = (Get-GitHubRelease -Repository $entry.repository -Channel $selectedChannel).tag_name
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
        ManagedId = if ($entry) { $entry.id } elseif ($installed) { $installed.ManagedId } else { $null }
        Repository = if ($entry) { $entry.repository } else { $null }
        LatestRelease = $latest
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
                    DefaultChannel = Get-OptionalValue -Object $_ -Name "defaultChannel" -Default "Stable"
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
            return Invoke-ManagedInstall -Entry $entry -Catalog $catalog -Paths $paths -ServiceName $ServiceName -Version $Version -Channel $Channel -BackupCount $BackupCount -DryRun:$DryRun
        }
        "update" {
            if (-not $Plugin) { throw "update requires a managed plugin id or name." }
            $entry = Get-CatalogEntry -Catalog $catalog -Reference $Plugin
            if (-not $entry) { throw "Plugin '$Plugin' is not in the managed catalog and cannot be updated automatically." }
            $inventory = Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $catalog
            if (-not (Resolve-InstalledPlugin -Reference $Plugin -Inventory $inventory)) { throw "Plugin '$Plugin' is not installed. Use install first." }
            return Invoke-ManagedInstall -Entry $entry -Catalog $catalog -Paths $paths -ServiceName $ServiceName -Version $Version -Channel $Channel -BackupCount $BackupCount -DryRun:$DryRun
        }
        "install-file" {
            if (-not $Path) { throw "install-file requires -Path <jar>." }
            return Invoke-LocalInstall -SourcePath $Path -Catalog $catalog -Paths $paths -ServiceName $ServiceName -BackupCount $BackupCount -DryRun:$DryRun
        }
        "remove" {
            if (-not $Plugin) { throw "remove requires a plugin reference." }
            $item = Resolve-InstalledPlugin -Reference $Plugin -Inventory (Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $catalog)
            if (-not $item) { throw "Plugin '$Plugin' is not installed or disabled." }
            return Invoke-RemovePlugin -Item $item -Paths $paths -ServiceName $ServiceName -BackupCount $BackupCount -DryRun:$DryRun -Force:$Force
        }
        "disable" {
            if (-not $Plugin) { throw "disable requires a plugin reference." }
            $item = Resolve-InstalledPlugin -Reference $Plugin -Inventory (Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $catalog)
            if (-not $item) { throw "Plugin '$Plugin' is not installed." }
            return Invoke-SetPluginEnabled -Item $item -Paths $paths -ServiceName $ServiceName -Enabled $false -DryRun:$DryRun
        }
        "enable" {
            if (-not $Plugin) { throw "enable requires a plugin reference." }
            $item = Resolve-InstalledPlugin -Reference $Plugin -Inventory (Get-InstalledPluginInventory -ServerPath $ServerPath -Catalog $catalog)
            if (-not $item) { throw "Plugin '$Plugin' is not installed." }
            return Invoke-SetPluginEnabled -Item $item -Paths $paths -ServiceName $ServiceName -Enabled $true -DryRun:$DryRun
        }
        "rollback" {
            if (-not $Plugin) { throw "rollback requires a plugin reference." }
            return Invoke-RollbackPlugin -Reference $Plugin -Catalog $catalog -Paths $paths -ServiceName $ServiceName -BackupCount $BackupCount -DryRun:$DryRun
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


