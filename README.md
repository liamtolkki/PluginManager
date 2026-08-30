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

Show local and release status for a plugin:

```powershell
.\plugin-manager.ps1 status sanctuary
```

Install the selected release of a managed plugin:

```powershell
.\plugin-manager.ps1 install sanctuary -Channel Prerelease
```

Install a specific release:

```powershell
.\plugin-manager.ps1 install sanctuary -Version 0.1.0-alpha.1
```

Update an installed managed plugin:

```powershell
.\plugin-manager.ps1 update sanctuary -Channel Prerelease
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
.\plugin-manager.ps1 remove Sanctuary
```

Restore the newest PluginManager backup for a plugin:

```powershell
.\plugin-manager.ps1 rollback Sanctuary
```

All mutating commands support `-DryRun`.

## Release channels

Managed GitHub plugins support:

```text
Stable
Prerelease
```

`-Version` overrides channel selection and resolves an exact GitHub Release tag. A leading `v` is optional.

The catalog can give each plugin its own default channel.

## Verification

PluginManager verifies a downloaded release before stopping Minecraft.

Verification uses, in order:

1. A configured `.sha256` release asset when one exists.
2. GitHub's SHA-256 release asset digest when the release API supplies one.

A release without either form of SHA-256 verification is rejected.

The downloaded JAR is also opened and inspected for `plugin.yml` or `paper-plugin.yml`. Its declared plugin name must match the catalog entry.

## Deployment behavior

For an install or update, PluginManager:

1. Resolves the requested GitHub Release.
2. Selects the configured JAR asset.
3. Downloads the JAR and verifies SHA-256.
4. Validates plugin metadata inside the JAR.
5. Detects duplicate matching installed JARs and refuses to continue if the installation is ambiguous.
6. Creates a timestamped backup of the current JAR when one exists.
7. Stops the Minecraft Windows service if it is running.
8. Replaces the plugin JAR.
9. Updates PluginManager state.
10. Restarts Minecraft only if it was running before the operation.
11. Restores the previous JAR if deployment fails.
12. Prunes old backups according to the configured retention count.

Plugin data directories are not deleted by install, update, disable, enable, remove, or rollback.

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

The initial catalog contains Sanctuary. Add new entries as independently deployable plugins begin publishing usable GitHub Release JARs.

## Existing plugins

PluginManager does not require a plugin to have been installed by PluginManager.

`list`, `remove`, `disable`, and `enable` inspect the actual JARs on disk. Existing plugins are therefore manageable even if they were copied into the server manually.

Automatic `update` requires a matching catalog entry because PluginManager needs an authoritative release source.

## Administrator requirement

Mutating operations that control the Windows service must run from an elevated PowerShell session.

Read-only commands such as `list`, `catalog`, and `status` do not require elevation.

## Testing

Tests use Pester:

```powershell
Invoke-Pester .\tests -CI
```

GitHub Actions runs the test suite on Windows for every push and pull request.
