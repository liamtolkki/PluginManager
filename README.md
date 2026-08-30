# PluginManager

PluginManager is an external PowerShell management tool for a Paper server.

It installs, updates, removes, disables, enables, inspects, and rolls back plugin JARs without hot-reloading plugins or replacing JARs while Paper is running.

## Why this is external

Paper recommends restarting the server when plugin JARs change. Runtime plugin reloads are unreliable, and replacing a JAR while the server is running is unsafe.

PluginManager therefore runs outside Paper and controls the Windows service that owns the server process.

This also means PluginManager can install a plugin before that plugin exists on the server.

## Default server layout

```text
C:\MinecraftServer\
  plugins\
  plugins-disabled\
  deploy\
    plugin-manager\
      state.json
      downloads\
      backups\
```

The default Windows service name is:

```text
MinecraftServer
```

Both paths can be overridden from the command line.

## Commands

List every discovered plugin JAR, including plugins that are not in the managed catalog:

```powershell
.\plugin-manager.ps1 list
```

Show plugins that PluginManager knows how to download from GitHub Releases:

```powershell
.\plugin-manager.ps1 catalog
```

The catalog output also shows declared managed-plugin dependencies.

Show local and release status for a plugin:

```powershell
.\plugin-manager.ps1 status sanctuary
```

Install the selected release of a managed plugin:

```powershell
.\plugin-manager.ps1 install sanctuary
```

Install a specific release:

```powershell
.\plugin-manager.ps1 install sanctuary -Version 0.1.0-alpha.1
```

Update one installed managed plugin:

```powershell
.\plugin-manager.ps1 update sanctuary
```

Preview every available managed-plugin update:

```powershell
.\plugin-manager.ps1 update-all -DryRun
```

Update every installed managed plugin in one deployment transaction:

```powershell
.\plugin-manager.ps1 update-all
```

Install a local JAR that is not in the managed catalog:

```powershell
.\plugin-manager.ps1 install-file -Path C:\Temp\SomePlugin.jar
```

Disable a plugin by moving its JAR outside Paper's plugin directory:

```powershell
.\plugin-manager.ps1 disable Sanctuary
```

Enable it again:

```powershell
.\plugin-manager.ps1 enable Sanctuary
```

Remove a plugin JAR while preserving its plugin data directory:

```powershell
.\plugin-manager.ps1 remove Sanctuary -Force
```

Restore the newest PluginManager backup for a plugin:

```powershell
.\plugin-manager.ps1 rollback Sanctuary
```

All mutating commands support `-DryRun`.

Read commands and dry-run output can be returned as JSON with `-Json`.

## Release channels

Managed GitHub plugins support:

```text
Stable
Prerelease
```

`-Version` overrides channel selection and resolves an exact GitHub Release tag. A leading `v` is optional.

The catalog can give each plugin its own default channel.

Passing `-Channel` to `update-all` overrides the configured default channel for every managed plugin considered by that run. Without it, each plugin uses its own catalog default.

## Verification

PluginManager verifies a downloaded release before stopping Minecraft.

Verification uses, in order:

1. A configured `.sha256` release asset when one exists.
2. GitHub's SHA-256 release asset digest when the release API supplies one.

A release without either form of SHA-256 verification is rejected.

The downloaded JAR is also opened and inspected for `plugin.yml` or `paper-plugin.yml`. Its declared plugin name must match the catalog entry.

## Single-plugin deployment behavior

For an individual install or update, PluginManager:

1. Resolves the requested GitHub Release.
2. Selects the configured JAR asset.
3. Downloads the JAR and verifies SHA-256.
4. Validates plugin metadata inside the JAR.
5. Detects duplicate matching installed JARs and refuses to continue if the installation is ambiguous.
6. Creates a timestamped backup of the current JAR when one exists.
7. Stops the Minecraft Windows service if it is running.
8. Replaces the plugin JAR.
9. Restarts Minecraft only if it was running before the operation.
10. Restores the previous JAR if deployment fails.
11. Updates PluginManager state.
12. Prunes old backups according to the configured retention count.

Plugin data directories are not deleted by install, update, disable, enable, remove, or rollback.

## Batch update behavior

`update-all` operates only on managed plugins that are already installed. It does not install every entry in the catalog.

Before stopping Minecraft, PluginManager:

1. Reads the installed managed-plugin inventory.
2. Validates the dependency graph.
3. Validates that enabled plugins have their declared dependencies installed and enabled.
4. Resolves the current release for each installed managed plugin.
5. Builds an update plan in dependency order.
6. Downloads every required JAR.
7. Verifies every SHA-256 value.
8. Validates the plugin metadata in every downloaded JAR.
9. Checks every target path for conflicts.
10. Backs up every JAR that will be replaced.

If any of those steps fail, the Minecraft service is never stopped.

After every candidate is ready, PluginManager stops `MinecraftServer` once, replaces all planned JARs in dependency order, and starts the service once.

If replacement or service startup fails, PluginManager stops the service if necessary, removes the staged replacements, restores every previous JAR, and returns the server to its previous running or stopped state.

State is updated only after the batch deployment succeeds.

## Managed dependencies

A catalog entry can declare dependencies on other independently deployable managed plugins:

```json
{
  "id": "example-plugin",
  "pluginName": "ExamplePlugin",
  "repository": "owner/ExamplePlugin",
  "assetPattern": "^ExamplePlugin\\.jar$",
  "installedFile": "ExamplePlugin.jar",
  "defaultChannel": "Stable",
  "dependsOn": [
    "shared-plugin"
  ]
}
```

Dependency values are stable PluginManager catalog IDs, not Paper plugin names or Java library names.

PluginManager rejects:

- dependencies on unknown managed IDs
- duplicate dependency declarations
- self-dependencies
- dependency cycles

Dependency behavior is:

- `install` installs missing managed dependencies first and enables disabled dependencies before installing the requested plugin.
- `update` ensures the requested plugin's dependencies are installed and enabled before updating it.
- `enable` ensures dependencies are installed and enabled first.
- `disable` is rejected when an enabled installed plugin depends on the target.
- `remove` is rejected when any installed plugin depends on the target, even if that dependent plugin is disabled.
- `update-all` updates dependencies before dependents and refuses to run if an enabled dependency relationship is already broken.

`-Force` is still required for `remove`, but it does not bypass dependency protection.

## Managed catalog

`plugins.json` contains independently deployable Paper plugins that PluginManager can install or update automatically.

Do not add Java libraries or dependencies that are bundled inside another plugin's shaded JAR. For example, ExtendedItems and ExtendedUI are bundled into Sanctuary and are not separate server plugins.

A catalog entry defines:

- stable plugin ID
- expected plugin name from plugin metadata
- GitHub repository
- release JAR asset pattern
- optional checksum asset pattern
- standardized installed filename
- legacy filename patterns
- default release channel
- optional managed-plugin dependencies through `dependsOn`

The current catalog contains Sanctuary. Sanctuary currently has no external managed-plugin dependencies.

Add new entries as independently deployable plugins begin publishing usable GitHub Release JARs.

## Existing plugins

PluginManager does not require a plugin to have been installed by PluginManager.

`list`, `remove`, `disable`, and `enable` inspect the actual JARs on disk. Existing plugins are therefore manageable even if they were copied into the server manually.

Automatic `update` and `update-all` require matching catalog entries because PluginManager needs an authoritative release source.

## Administrator requirement

Mutating operations that control the Windows service must run from an elevated PowerShell session.

Read-only commands such as `list`, `catalog`, and `status` do not require elevation.

## PowerShell support

PluginManager is tested with both Windows PowerShell 5.1 and PowerShell 7 on Windows.

This matters for the server environment because Windows PowerShell and PowerShell 7 handle some JSON and collection behavior differently.

## Testing

Tests use Pester:

```powershell
Invoke-Pester .\tests -CI
```

GitHub Actions validates PowerShell syntax, runs compatibility checks under Windows PowerShell 5.1, and runs the Pester suite on every push and pull request.
