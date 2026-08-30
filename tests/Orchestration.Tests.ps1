BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot "PluginManager.Orchestration.psm1") -Force

    function New-TestCatalog {
        param([object[]]$Plugins)
        return [pscustomobject]@{
            schemaVersion = 1
            plugins = $Plugins
        }
    }

    function New-TestCatalogEntry {
        param(
            [Parameter(Mandatory)][string]$Id,
            [string[]]$DependsOn = @()
        )

        return [pscustomobject]@{
            id = $Id
            pluginName = $Id
            repository = "example/$Id"
            assetPattern = "^$Id\\.jar$"
            installedFile = "$Id.jar"
            defaultChannel = "Stable"
            dependsOn = $DependsOn
        }
    }
}

Describe "Dependency graph" {
    It "orders dependencies before dependents" {
        $catalog = New-TestCatalog @(
            (New-TestCatalogEntry -Id "base"),
            (New-TestCatalogEntry -Id "feature" -DependsOn @("base")),
            (New-TestCatalogEntry -Id "app" -DependsOn @("feature"))
        )

        $order = @(Get-DependencyOrder -Catalog $catalog -RootId "app")

        $order.Count | Should -Be 3
        $order[0] | Should -Be "base"
        $order[1] | Should -Be "feature"
        $order[2] | Should -Be "app"
    }

    It "rejects unknown dependencies" {
        $catalog = New-TestCatalog @(
            (New-TestCatalogEntry -Id "app" -DependsOn @("missing"))
        )

        { Assert-CatalogDependencyGraph -Catalog $catalog } |
            Should -Throw "*depends on unknown managed plugin 'missing'*"
    }

    It "rejects dependency cycles" {
        $catalog = New-TestCatalog @(
            (New-TestCatalogEntry -Id "a" -DependsOn @("b")),
            (New-TestCatalogEntry -Id "b" -DependsOn @("a"))
        )

        { Assert-CatalogDependencyGraph -Catalog $catalog } |
            Should -Throw "*dependency cycle detected*"
    }
}

Describe "Dependency mutation guards" {
    BeforeEach {
        $script:catalog = New-TestCatalog @(
            (New-TestCatalogEntry -Id "base"),
            (New-TestCatalogEntry -Id "app" -DependsOn @("base"))
        )
        $script:base = [pscustomobject]@{
            Name = "base"
            ManagedId = "base"
            Enabled = $true
            FileName = "base.jar"
            Path = "C:\server\plugins\base.jar"
        }
    }

    It "blocks removal while an installed dependent exists" {
        $app = [pscustomobject]@{
            Name = "app"
            ManagedId = "app"
            Enabled = $false
            FileName = "app.jar"
            Path = "C:\server\plugins-disabled\app.jar"
        }
        $inventory = @($script:base, $app)

        { Assert-PluginMutationAllowed -Catalog $script:catalog -Inventory $inventory -Item $script:base -Operation remove } |
            Should -Throw "*installed plugin(s) depend on it: app*"
    }

    It "allows disable when all dependents are already disabled" {
        $app = [pscustomobject]@{
            Name = "app"
            ManagedId = "app"
            Enabled = $false
            FileName = "app.jar"
            Path = "C:\server\plugins-disabled\app.jar"
        }
        $inventory = @($script:base, $app)

        { Assert-PluginMutationAllowed -Catalog $script:catalog -Inventory $inventory -Item $script:base -Operation disable } |
            Should -Not -Throw
    }

    It "blocks disable while an enabled dependent exists" {
        $app = [pscustomobject]@{
            Name = "app"
            ManagedId = "app"
            Enabled = $true
            FileName = "app.jar"
            Path = "C:\server\plugins\app.jar"
        }
        $inventory = @($script:base, $app)

        { Assert-PluginMutationAllowed -Catalog $script:catalog -Inventory $inventory -Item $script:base -Operation disable } |
            Should -Throw "*installed plugin(s) depend on it: app*"
    }
}

Describe "Batch update dry run" {
    It "returns the complete planned update set without touching the service" {
        $server = Join-Path $TestDrive "server"
        New-Item -ItemType Directory -Path (Join-Path $server "plugins") -Force | Out-Null
        $catalog = New-TestCatalog @((New-TestCatalogEntry -Id "app"))

        Mock -ModuleName PluginManager.Orchestration Get-ManagedUpdatePlan {
            return @(
                [pscustomobject]@{
                    Name = "app"
                    FromVersion = "1.0.0"
                    Version = "1.1.0"
                    ReleaseTag = "v1.1.0"
                    Enabled = $true
                }
            )
        }
        Mock -ModuleName PluginManager.Orchestration Get-Service {
            throw "Service access should not occur during a dry run."
        }

        $result = @(Invoke-UpdateAll -Catalog $catalog -ServerPath $server -ServiceName "MinecraftServer" -DryRun)

        $result.Count | Should -Be 1
        $result[0].Name | Should -Be "app"
        $result[0].FromVersion | Should -Be "1.0.0"
        $result[0].Version | Should -Be "1.1.0"
        $result[0].DryRun | Should -BeTrue
        Should -Invoke -ModuleName PluginManager.Orchestration Get-Service -Times 0
    }
}
