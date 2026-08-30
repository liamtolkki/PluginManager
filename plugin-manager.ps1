[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("list", "catalog", "status", "install", "update", "update-all", "install-file", "remove", "disable", "enable", "rollback")]
    [string]$Command = "list",

    [Parameter(Position = 1)]
    [string]$Plugin,

    [string]$Path,

    [string]$Version,

    [ValidateSet("Stable", "Prerelease")]
    [string]$Channel,

    [string]$ServerPath = "C:\MinecraftServer",

    [string]$ServiceName = "MinecraftServer",

    [string]$CatalogPath = (Join-Path $PSScriptRoot "plugins.json"),

    [ValidateRange(1, 100)]
    [int]$BackupCount = 10,

    [switch]$DryRun,

    [switch]$Force,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "PluginManager.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "PluginManager.Orchestration.psm1") -Force

$catalog = Get-PluginCatalog -CatalogPath $CatalogPath
Assert-CatalogDependencyGraph -Catalog $catalog

$coreParameters = @{
    Command = $Command
    Plugin = $Plugin
    Path = $Path
    Version = $Version
    ServerPath = $ServerPath
    ServiceName = $ServiceName
    CatalogPath = $CatalogPath
    BackupCount = $BackupCount
    DryRun = $DryRun
    Force = $Force
}
if ($Channel) {
    $coreParameters.Channel = $Channel
}

switch ($Command) {
    "catalog" {
        $result = @($catalog.plugins | ForEach-Object {
            $dependencies = @(Get-CatalogDependencyIds -Entry $_)
            [pscustomobject]@{
                Id = $_.id
                Name = $_.pluginName
                DefaultChannel = if ($_.defaultChannel) { $_.defaultChannel } else { "Stable" }
                DependsOn = if ($dependencies.Count -gt 0) { $dependencies -join ", " } else { "-" }
                Repository = $_.repository
            }
        })
    }
    "install" {
        if (-not $Plugin) {
            throw "install requires a managed plugin id or name."
        }
        $parameters = @{
            Catalog = $catalog
            Plugin = $Plugin
            ServerPath = $ServerPath
            ServiceName = $ServiceName
            CatalogPath = $CatalogPath
            BackupCount = $BackupCount
            Version = $Version
            DryRun = $DryRun
        }
        if ($Channel) {
            $parameters.Channel = $Channel
        }
        $result = Invoke-DependencyAwareInstall @parameters
    }
    "update" {
        if (-not $Plugin) {
            throw "update requires a managed plugin id or name."
        }
        $parameters = @{
            Catalog = $catalog
            Plugin = $Plugin
            ServerPath = $ServerPath
            ServiceName = $ServiceName
            CatalogPath = $CatalogPath
            BackupCount = $BackupCount
            Version = $Version
            DryRun = $DryRun
            RequireInstalled = $true
        }
        if ($Channel) {
            $parameters.Channel = $Channel
        }
        $result = Invoke-DependencyAwareInstall @parameters
    }
    "update-all" {
        $parameters = @{
            Catalog = $catalog
            ServerPath = $ServerPath
            ServiceName = $ServiceName
            BackupCount = $BackupCount
            DryRun = $DryRun
        }
        if ($Channel) {
            $parameters.Channel = $Channel
        }
        $result = Invoke-UpdateAll @parameters
    }
    "remove" {
        if (-not $Plugin) {
            throw "remove requires a plugin reference."
        }
        $result = Invoke-DependencyGuardedMutation \
            -Catalog $catalog \
            -Command remove \
            -Plugin $Plugin \
            -ServerPath $ServerPath \
            -ServiceName $ServiceName \
            -CatalogPath $CatalogPath \
            -BackupCount $BackupCount \
            -DryRun:$DryRun \
            -Force:$Force
    }
    "disable" {
        if (-not $Plugin) {
            throw "disable requires a plugin reference."
        }
        $result = Invoke-DependencyGuardedMutation \
            -Catalog $catalog \
            -Command disable \
            -Plugin $Plugin \
            -ServerPath $ServerPath \
            -ServiceName $ServiceName \
            -CatalogPath $CatalogPath \
            -BackupCount $BackupCount \
            -DryRun:$DryRun
    }
    "enable" {
        if (-not $Plugin) {
            throw "enable requires a plugin reference."
        }
        $result = Invoke-DependencyAwareEnable \
            -Catalog $catalog \
            -Plugin $Plugin \
            -ServerPath $ServerPath \
            -ServiceName $ServiceName \
            -CatalogPath $CatalogPath \
            -BackupCount $BackupCount \
            -DryRun:$DryRun
    }
    default {
        $result = Invoke-PluginManager @coreParameters
    }
}

if ($null -eq $result) {
    exit 0
}

if ($Json) {
    $result | ConvertTo-Json -Depth 10
    exit 0
}

switch ($Command) {
    "list" {
        $result |
            Sort-Object @{ Expression = "Enabled"; Descending = $true }, Name |
            Format-Table Name, Version, Enabled, Managed, ManagedId, FileName -AutoSize
    }
    "catalog" {
        $result | Sort-Object Id | Format-Table Id, Name, DefaultChannel, DependsOn, Repository -AutoSize
    }
    "status" {
        $result | Format-List
    }
    "update-all" {
        if (@($result).Count -eq 0) {
            Write-Host "All installed managed plugins are current."
        }
        else {
            $result | Format-Table Name, FromVersion, Version, ReleaseTag, Enabled, Changed -AutoSize
        }
    }
    default {
        $result
    }
}
