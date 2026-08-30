BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot "PluginManager.psm1") -Force
    $catalogPath = Join-Path $repoRoot "plugins.json"
}

Describe "Plugin catalog" {
    It "loads the initial catalog" {
        $catalog = Get-PluginCatalog -CatalogPath $catalogPath

        $catalog.schemaVersion | Should -Be 1
        @($catalog.plugins).Count | Should -BeGreaterThan 0
        (Get-CatalogEntry -Catalog $catalog -Reference "sanctuary").pluginName | Should -Be "Sanctuary"
        (Get-CatalogEntry -Catalog $catalog -Reference "SANCTUARY").id | Should -Be "sanctuary"
    }
}

Describe "Plugin JAR metadata" {
    BeforeEach {
        $contentDirectory = Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $contentDirectory -Force | Out-Null
        Set-Content -Path (Join-Path $contentDirectory "plugin.yml") -Encoding utf8 -Value @"
name: Sanctuary
version: '0.1.0-alpha.1'
main: example.Main
"@

        $zipPath = Join-Path $TestDrive (([Guid]::NewGuid().ToString("N")) + ".zip")
        Compress-Archive -Path (Join-Path $contentDirectory "*") -DestinationPath $zipPath
        $script:jarPath = [System.IO.Path]::ChangeExtension($zipPath, ".jar")
        Move-Item -Path $zipPath -Destination $script:jarPath
    }

    It "reads plugin name and version" {
        $metadata = Get-PluginJarMetadata -Path $script:jarPath

        $metadata.Name | Should -Be "Sanctuary"
        $metadata.Version | Should -Be "0.1.0-alpha.1"
        $metadata.MetadataFile | Should -Be "plugin.yml"
    }

    It "discovers existing managed JARs" {
        $server = Join-Path $TestDrive "server"
        $plugins = Join-Path $server "plugins"
        New-Item -ItemType Directory -Path $plugins -Force | Out-Null
        Copy-Item -Path $script:jarPath -Destination (Join-Path $plugins "sanctuary-0.1.0-alpha.1.jar")

        $catalog = Get-PluginCatalog -CatalogPath $catalogPath
        $inventory = @(Get-InstalledPluginInventory -ServerPath $server -Catalog $catalog)

        $inventory.Count | Should -Be 1
        $inventory[0].Name | Should -Be "Sanctuary"
        $inventory[0].Managed | Should -BeTrue
        $inventory[0].ManagedId | Should -Be "sanctuary"
        $inventory[0].Enabled | Should -BeTrue
    }
}

Describe "Release asset selection" {
    It "selects exactly one matching JAR" {
        $release = [pscustomobject]@{
            tag_name = "v1.0.0"
            assets = @(
                [pscustomobject]@{ name = "Example.jar"; digest = "sha256:" + ("a" * 64) },
                [pscustomobject]@{ name = "Example.jar.sha256"; digest = $null }
            )
        }

        $asset = Resolve-ReleaseAsset -Release $release -Pattern '^Example\.jar$' -Purpose "plugin JAR"
        $asset.name | Should -Be "Example.jar"
    }

    It "uses a GitHub SHA-256 digest when no checksum asset is configured" {
        $hash = "0123456789abcdef" * 4
        $release = [pscustomobject]@{ tag_name = "v1.0.0"; assets = @() }
        $asset = [pscustomobject]@{ name = "Example.jar"; digest = "sha256:$hash" }

        $actual = Get-ExpectedSha256 -Release $release -JarAsset $asset -DownloadDirectory $TestDrive
        $actual | Should -Be $hash
    }

    It "rejects releases without a verifiable SHA-256" {
        $release = [pscustomobject]@{ tag_name = "v1.0.0"; assets = @() }
        $asset = [pscustomobject]@{ name = "Example.jar"; digest = $null }

        { Get-ExpectedSha256 -Release $release -JarAsset $asset -DownloadDirectory $TestDrive } |
            Should -Throw "*does not provide a usable SHA-256*"
    }
}
