[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("list", "catalog", "status", "install", "update", "install-file", "remove", "disable", "enable", "rollback")]
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

$parameters = @{
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
    $parameters.Channel = $Channel
}

$result = Invoke-PluginManager @parameters

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
        $result | Sort-Object Id | Format-Table Id, Name, DefaultChannel, Repository -AutoSize
    }
    "status" {
        $result | Format-List
    }
    default {
        $result
    }
}
