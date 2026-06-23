# pwsh-profile

A cross-machine PowerShell 7 profile with a built-in field toolkit (network discovery, MAC vendor lookup, DVR config helpers). Designed so any machine I sign into gets the same prompt, aliases, and tooling with a single command.

## Install

Open PowerShell **as Administrator** (first-time setup needs elevation) and run:

```powershell
irm https://raw.githubusercontent.com/b8usap/pwsh-profile/main/bootstrap.ps1 | iex
```

The bootstrap will:
1. Install git if missing (via winget).
2. Clone this repo to `%LOCALAPPDATA%\pwsh-profile`.
3. Write a small stub to `$PROFILE` that loads the cloned `profile.ps1`.

Restart PowerShell. On the first new session, first-time setup will install Oh My Posh, a Nerd Font (CaskaydiaCove), Terminal-Icons, zoxide, and Chocolatey — once per machine.

After the first launch finishes, set your terminal font to **CaskaydiaCove NF** for the Oh My Posh prompt to render correctly.

## Updating

The stub does a throttled `git pull` in a background job at most once per 24 hours. To force an immediate update:

```powershell
git -C $env:LOCALAPPDATA\pwsh-profile pull
```

## Editing

The real profile lives at `%LOCALAPPDATA%\pwsh-profile\profile.ps1`. Two shortcuts:

- `epr` — opens the real profile in your editor (preferred for normal edits)
- `ep`  — opens the `$PROFILE` stub (rarely needed)

Edit, then `cd %LOCALAPPDATA%\pwsh-profile && git add . && git commit -m "..." && git push`. Other machines pick it up on next shell open.

## Adding a field tool

Drop a `.ps1` into `tools/` and commit. It's auto-loaded on shell open. Give each top-level function a `.SYNOPSIS` comment block so it shows up nicely in the `Show-FieldTools` banner:

```powershell
function Do-Thing {
    <#
    .SYNOPSIS
        One-line description.
    #>
    ...
}
```

## Files

| File | Purpose |
|---|---|
| `profile.ps1`     | The real profile, dot-sourced by the stub at `$PROFILE` |
| `tools/*.ps1`     | Auto-loaded field utilities |
| `bootstrap.ps1`   | One-shot installer for new PCs |
| `.gitignore`      | Excludes per-machine state and the rebuildable OUI database |

## Per-machine state (not in git)

- `~\.config\omp\.setup-complete` — sentinel that marks first-time setup done
- `~\.config\omp\theme.omp.json` — Oh My Posh theme, downloaded on first setup
- `~\.config\omp\.last-ps-update-check` — throttles the PowerShell version check
- `%LOCALAPPDATA%\pwsh-profile\.last-pull` — throttles the auto-pull
- `tools/oui.json` — rebuildable IEEE OUI database; run `Update-OuiDatabase` on first use

## Opt-outs

Set these env vars per-machine (`setx FOO 1`) to change behavior:

- `PROFILE_QUIET=1` — suppress the startup banner
- `PROFILE_SKIP_UPDATE_CHECK=1` — skip the daily PowerShell-version check (handy where GitHub is firewalled)
- `PROFILE_TOOLKIT_PATH=<path>` — load tools from a different folder than the repo's `tools/` (rare; for testing)
