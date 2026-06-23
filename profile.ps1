### PowerShell Profile
### Version 5.0 — Git-distributed profile + colocated field toolkit
###
### Lives in a cloned git repo (default: %LOCALAPPDATA%\pwsh-profile) and is
### dot-sourced by a small stub at $PROFILE on each machine. Edit profile.ps1
### in the clone, commit, push — every other machine pulls on next shell open.
### Per-machine work (winget installs, fonts, sentinel) is handled by the
### first-time setup block below — runs once per device, then no-ops forever.
###
### Tools live in $PSScriptRoot\tools alongside this file and are auto-loaded
### on shell start. Drop a new .ps1 into tools/ and commit.

# ── Internal Helpers (needed early) ──────────────────────────────────────────

function Test-CommandExists {
    param($command)
    return $null -ne (Get-Command $command -ErrorAction SilentlyContinue)
}

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK   { param($msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Skip { param($msg) Write-Host "    [--] $msg (already present, skipping)" -ForegroundColor DarkGray }
function Write-Warn { param($msg) Write-Host "    [!!] $msg" -ForegroundColor Yellow }

# ── First-Time Setup ──────────────────────────────────────────────────────────

$script:SetupSentinel = "$HOME\.config\omp\.setup-complete"

function Invoke-ProfileSetup {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  First-time setup detected. Installing environment..." -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan

    $isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isElevated) {
        Write-Warn "Setup requires an elevated (Administrator) shell."
        Write-Warn "Please restart PowerShell as Administrator and open a new session."
        Write-Warn "To skip setup and run manually later, create this file:"
        Write-Warn "  New-Item -Force '$script:SetupSentinel'"
        return
    }

    Write-Step "Checking winget"
    if (-not (Test-CommandExists 'winget')) {
        Write-Warn "winget not found. Install 'App Installer' from the Microsoft Store, then restart your shell."
        return
    }
    Write-OK "winget available."

    function Install-WingetPackage {
        param([string]$Id, [string]$Name)
        Write-Step "Installing $Name"
        if (winget list --id $Id --accept-source-agreements 2>$null | Select-String $Id) {
            Write-Skip $Name
        } else {
            winget install --id $Id -e --accept-source-agreements --accept-package-agreements
            Write-OK "$Name installed."
        }
    }

    Install-WingetPackage -Id 'JanDeDobbeleer.OhMyPosh' -Name 'Oh My Posh'

    # Refresh PATH so oh-my-posh is usable immediately in this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'User')

    Write-Step "Installing Nerd Font (CaskaydiaCove)"
    try {
        oh-my-posh font install CascadiaCode
        Write-OK "CaskaydiaCove Nerd Font installed."
        Write-Warn "Set your terminal font to 'CaskaydiaCove NF' in your terminal settings."
    } catch {
        Write-Warn "Font install failed: $_"
        Write-Warn "Install manually from: https://www.nerdfonts.com/font-downloads"
    }

    Write-Step "Saving Oh My Posh theme locally"
    $ompConfigDir = "$HOME\.config\omp"
    $ompThemeDest = "$ompConfigDir\theme.omp.json"
    $ompThemeUrl  = "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/jandedobbeleer.omp.json"

    if (-not (Test-Path $ompConfigDir)) {
        New-Item -ItemType Directory -Path $ompConfigDir -Force | Out-Null
    }

    try {
        Invoke-RestMethod -Uri $ompThemeUrl -OutFile $ompThemeDest
        Write-OK "Theme saved to $ompThemeDest"
    } catch {
        Write-Warn "Could not download theme: $_"
        Write-Warn "Copy a .omp.json theme manually to: $ompThemeDest"
    }

    Write-Step "Installing Terminal-Icons module"
    if (Get-Module -ListAvailable -Name Terminal-Icons) {
        Write-Skip "Terminal-Icons"
    } else {
        Install-Module -Name Terminal-Icons -Scope CurrentUser -Force -SkipPublisherCheck
        Write-OK "Terminal-Icons installed."
    }

    Install-WingetPackage -Id 'ajeetdsouza.zoxide' -Name 'zoxide'

    Write-Step "Installing Chocolatey"
    if (Test-CommandExists 'choco') {
        Write-Skip "Chocolatey"
    } else {
        try {
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
            Write-OK "Chocolatey installed."
        } catch {
            Write-Warn "Chocolatey install failed: $_"
        }
    }

    New-Item -ItemType File -Path $script:SetupSentinel -Force | Out-Null

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Magenta
    Write-Host "  Setup complete! Please restart your PowerShell session." -ForegroundColor Magenta
    Write-Host ""
    Write-Host "  Don't forget: set your terminal font to 'CaskaydiaCove NF'" -ForegroundColor White
    Write-Host "  To change your OMP theme, replace:" -ForegroundColor White
    Write-Host "    $HOME\.config\omp\theme.omp.json" -ForegroundColor DarkGray
    Write-Host "  Browse themes at: https://ohmyposh.dev/docs/themes" -ForegroundColor DarkGray
    Write-Host "================================================================" -ForegroundColor Magenta
    Write-Host ""
}

if (-not (Test-Path $script:SetupSentinel)) {
    Invoke-ProfileSetup
    # If setup just completed, bail out so the user restarts fresh.
    # Newly installed tools won't be on PATH until a new session anyway.
    if (Test-Path $script:SetupSentinel) { return }
}

# ── Module Imports ────────────────────────────────────────────────────────────

if (Get-Module -ListAvailable -Name Terminal-Icons) {
    Import-Module -Name Terminal-Icons
}

$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path $ChocolateyProfile) {
    Import-Module "$ChocolateyProfile"
}

# ── Admin Check & Window Title ────────────────────────────────────────────────

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function prompt {
    if ($isAdmin) { "[" + (Get-Location) + "] # " } else { "[" + (Get-Location) + "] $ " }
}

$adminSuffix = if ($isAdmin) { " [ADMIN]" } else { "" }
$Host.UI.RawUI.WindowTitle = "PowerShell {0}$adminSuffix" -f $PSVersionTable.PSVersion.ToString()

# ── Editor Configuration ──────────────────────────────────────────────────────

$EDITOR = if     (Test-CommandExists 'notepad++')   { 'notepad++' }
          elseif (Test-CommandExists 'pvim')         { 'pvim' }
          elseif (Test-CommandExists 'vim')          { 'vim' }
          elseif (Test-CommandExists 'vi')           { 'vi' }
          elseif (Test-CommandExists 'code')         { 'code' }
          elseif (Test-CommandExists 'sublime_text') { 'sublime_text' }
          else                                       { 'notepad' }

Set-Alias -Name edit -Value $EDITOR

function Edit-Profile { & $EDITOR $PROFILE }
Set-Alias -Name ep -Value Edit-Profile

# Edit the REAL profile in the cloned repo (what $PROFILE stub dot-sources).
# Use this for normal edits; `ep` opens only the stub.
function Edit-RealProfile { & $EDITOR $PSCommandPath }
Set-Alias -Name epr -Value Edit-RealProfile

# ── File & Directory Utilities ────────────────────────────────────────────────

function touch($file) { "" | Out-File $file -Encoding ASCII }
function nf { param($name) New-Item -ItemType "file" -Path . -Name $name }
function mkcd { param($dir) mkdir $dir -Force; Set-Location $dir }

function unzip ($file) {
    Write-Output "Extracting $file to $pwd"
    $fullFile = Get-ChildItem -Path $pwd -Filter $file | ForEach-Object { $_.FullName }
    Expand-Archive -Path $fullFile -DestinationPath $pwd
}

function ff($name) {
    Get-ChildItem -Recurse -Filter "*${name}*" -ErrorAction SilentlyContinue | ForEach-Object {
        "$($_.Directory)\$($_)"
    }
}

function head {
    param($Path, $n = 10)
    Get-Content $Path -Head $n
}

function tail {
    param($Path, $n = 10)
    Get-Content $Path -Tail $n
}

# ── Navigation Shortcuts ──────────────────────────────────────────────────────

function docs { Set-Location -Path $HOME\Documents }
function down { Set-Location -Path $HOME\Downloads }
function dtop { Set-Location -Path $HOME\Desktop }

# ── Network Utilities ─────────────────────────────────────────────────────────

function Get-PubIP { (Invoke-WebRequest http://ifconfig.me/ip).Content }
function flushdns  { Clear-DnsClientCache }

# ── System Utilities ──────────────────────────────────────────────────────────

function uptime {
    if ($PSVersionTable.PSVersion.Major -eq 5) {
        Get-WmiObject win32_operatingsystem |
            Select-Object @{Name='LastBootUpTime'; Expression={$_.ConverttoDateTime($_.lastbootuptime)}} |
            Format-Table -HideTableHeaders
    } else {
        net statistics workstation | Select-String "since" |
            ForEach-Object { $_.ToString().Replace('Statistics since ', '') }
    }
}

function sysinfo        { Get-ComputerInfo }
function df             { Get-Volume }
function reload-profile { & $PROFILE }

# ── Text Processing ───────────────────────────────────────────────────────────

function grep {
    $caseSensitive = $true
    $pattern = $null
    $dir = $null

    foreach ($arg in $args) {
        if ($arg -match '^-[a-z]*i[a-z]*$') { $caseSensitive = $false }
        elseif ($arg -notmatch '^-') {
            if (-not $pattern) { $pattern = $arg }
            else { $dir = $arg }
        }
    }

    if (-not $pattern) { Write-Error "grep: no pattern specified"; return }

    if ($dir) {
        Get-ChildItem $dir | Select-String -Pattern $pattern -CaseSensitive:$caseSensitive
    } else {
        $input | Select-String -Pattern $pattern -CaseSensitive:$caseSensitive
    }
}

function sed($file, $find, $replace) {
    (Get-Content $file).Replace("$find", $replace) | Set-Content $file
}

# ── Process Management ────────────────────────────────────────────────────────

function which($name) { Get-Command $name | Select-Object -ExpandProperty Definition }
function export($name, $value) { Set-Item -Force -Path "env:$name" -Value $value }
function pkill($name) { Get-Process $name -ErrorAction SilentlyContinue | Stop-Process }
function pgrep($name) { Get-Process $name }
function k9 { Stop-Process -Name $args[0] }

# ── Clipboard ─────────────────────────────────────────────────────────────────

function cpy { Set-Clipboard $args[0] }
function pst { Get-Clipboard }

# ── Hastebin Upload ───────────────────────────────────────────────────────────

function hb {
    if ($args.Length -eq 0) { Write-Error "No file path specified."; return }
    $FilePath = $args[0]
    if (-not (Test-Path $FilePath)) { Write-Error "File path does not exist."; return }

    $Content = Get-Content $FilePath -Raw
    try {
        $response = Invoke-RestMethod -Uri "http://bin.christitus.com/documents" -Method Post -Body $Content -ErrorAction Stop
        "http://bin.christitus.com/$($response.key)"
    } catch {
        Write-Error "Failed to upload the document. Error: $_"
    }
}

# ── Git Shortcuts ─────────────────────────────────────────────────────────────

function gs { git status }
function ga { git add . }
function gc { param($m) git commit -m "$m" }
function gp { git push }
function g  { z Github }

function gcom {
    git add .
    git commit -m "$args"
}

function lazyg {
    git add .
    git commit -m "$args"
    git push
}

# ── Directory Listing ─────────────────────────────────────────────────────────

function la { Get-ChildItem -Path . -Force | Format-Table -AutoSize }
function ll { Get-ChildItem -Path . -Force -Hidden | Format-Table -AutoSize }

# ── Setup Management ──────────────────────────────────────────────────────────

function Reset-ProfileSetup {
    <#
    .SYNOPSIS
        Removes the setup sentinel so setup runs again on next shell open.
        Useful after a clean reinstall or on a machine that needs re-provisioning.
    #>
    if (Test-Path $script:SetupSentinel) {
        Remove-Item $script:SetupSentinel -Force
        Write-Host "Sentinel removed. Restart your shell to trigger setup." -ForegroundColor Yellow
    } else {
        Write-Host "No sentinel found — setup will already run on next shell open." -ForegroundColor DarkGray
    }
}

# ── PSReadLine Colours ────────────────────────────────────────────────────────

Set-PSReadLineOption -Colors @{
    Command   = 'Yellow'
    Parameter = 'Green'
    String    = 'DarkCyan'
}

# ── PowerShell Update Check ───────────────────────────────────────────────────

function Check-PSUpdate {
    # Notify only — never run winget at startup. A synchronous winget upgrade
    # blocks the shell for 20+ seconds and can disrupt later profile steps
    # (OMP init, etc.). Run 'Update-PowerShell' manually when you want to upgrade.
    $sentinel = "$HOME\.config\omp\.last-ps-update-check"
    if (Test-Path $sentinel) {
        $lastCheck = (Get-Item $sentinel).LastWriteTime
        if ((Get-Date) - $lastCheck -lt [TimeSpan]::FromHours(24)) { return }
    }

    try {
        $current = $PSVersionTable.PSVersion
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -TimeoutSec 5
        $latest  = [Version]($release.tag_name -replace '^v', '')

        if ($latest -gt $current) {
            Write-Host ""
            Write-Host "    [!!] PowerShell $latest is available (you have $current)." -ForegroundColor Yellow
            Write-Host "    Run 'Update-PowerShell' to upgrade." -ForegroundColor DarkGray
            Write-Host ""
        }
    } catch {
        # Silent fail — no internet, API rate limit, corporate proxy, etc.
        # Don't block shell startup.
    } finally {
        # Touch the sentinel REGARDLESS of outcome so a failed or slow check
        # (e.g. GitHub blocked behind a corporate proxy, which stalls to the
        # 5s timeout) does not repeat on every single launch. Writing this in
        # the try after the request — as a previous version did — meant a
        # failed request never recorded the check, so every cold start paid
        # the full timeout. -Force creates the parent dir if missing.
        New-Item -ItemType File -Path $sentinel -Force | Out-Null
    }
}

function Update-PowerShell {
    <#
    .SYNOPSIS
        Upgrades PowerShell to the latest stable release via winget.
        Self-elevates if not already running as administrator.
    #>
    if (-not $isAdmin) {
        Write-Host "Elevation required. Launching admin PowerShell..." -ForegroundColor Yellow
        Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-Command', @'
winget upgrade --id Microsoft.PowerShell --silent --accept-source-agreements --accept-package-agreements
Write-Host ""
Write-Host "Upgrade complete. Close this window and reopen PowerShell." -ForegroundColor Green
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
'@
        return
    }

    winget upgrade --id Microsoft.PowerShell --silent --accept-source-agreements --accept-package-agreements
    Write-Host "Restart PowerShell to use the new version." -ForegroundColor Green
}

# ── Oh My Posh ────────────────────────────────────────────────────────────────
# OMP runs BEFORE the update check so the prompt is set even if anything
# downstream misbehaves. (Previous order: Check-PSUpdate first, which on
# failure could disrupt OMP init and leave you with the fallback prompt.)

$ompTheme = "$HOME\.config\omp\theme.omp.json"

if (Test-CommandExists 'oh-my-posh') {
    if (Test-Path $ompTheme) {
        oh-my-posh init pwsh --config $ompTheme | Invoke-Expression
    } else {
        Write-Warn "OMP theme not found at $ompTheme — run Reset-ProfileSetup to re-provision."
    }
}

# ── Zoxide ────────────────────────────────────────────────────────────────────

if (Test-CommandExists 'zoxide') {
    Invoke-Expression (& { (zoxide init powershell | Out-String) })
}

# Run the update check last (after prompt + tools are already in place).
# Set PROFILE_SKIP_UPDATE_CHECK=1 on a machine to skip it entirely — useful on
# locked-down networks where GitHub is firewalled (one slow check per 24h).
if (-not $env:PROFILE_SKIP_UPDATE_CHECK) { Check-PSUpdate }

# ── Field Tools Auto-Loader ──────────────────────────────────────────────────
# Loads every .ps1 file from the toolkit folder on shell start so dropping
# a new tool into the folder makes it available everywhere on next launch.
#
# Resolution order:
#   1. $env:PROFILE_TOOLKIT_PATH (override — useful for testing or unusual setups)
#   2. $PSScriptRoot\tools (default — colocated with this profile in the repo)
#
# Mark-of-the-Web is cleared automatically. Banner output (stream 6) is
# suppressed for a clean startup — use Show-FieldTools to see what loaded.

$FieldToolsPath = $null

if ($env:PROFILE_TOOLKIT_PATH -and (Test-Path $env:PROFILE_TOOLKIT_PATH)) {
    $FieldToolsPath = $env:PROFILE_TOOLKIT_PATH
} else {
    $candidate = Join-Path $PSScriptRoot 'tools'
    if (Test-Path $candidate) { $FieldToolsPath = $candidate }
}

# Profile-native functions to surface in the startup banner alongside the
# toolkit tools. Each listed name needs comment-based help (.SYNOPSIS) to show
# a description; otherwise it renders as "(no .SYNOPSIS)".
$script:ProfileBuiltins = @(
    'Update-PowerShell'
    'Show-ProfileTools'
)

function Show-ProfileTools {
    <#
    .SYNOPSIS
        Cheatsheet of the built-in profile shortcuts, grouped by category.
    #>
    [CmdletBinding()]
    param()

    $sep = '─' * 76

    $categories = [ordered]@{
        'Admin & Window Title' = @(
            [pscustomobject]@{ N='prompt';          D='Prompt marks Admin sessions with # (automatic)' }
        )
        'Editor' = @(
            [pscustomobject]@{ N='edit <file>';     D='Open a file in your detected editor ($EDITOR)' }
            [pscustomobject]@{ N='ep';              D='Edit this profile (alias for Edit-Profile)' }
        )
        'Files & Directories' = @(
            [pscustomobject]@{ N='touch <file>';    D='Create an empty file' }
            [pscustomobject]@{ N='nf <name>';       D='New file in the current directory' }
            [pscustomobject]@{ N='mkcd <dir>';      D='Create a directory and cd into it' }
            [pscustomobject]@{ N='unzip <file>';    D='Extract a .zip into the current directory' }
            [pscustomobject]@{ N='ff <name>';       D='Find files by name, recursively (wildcard)' }
            [pscustomobject]@{ N='head <file> [n]'; D='First n lines of a file (default 10)' }
            [pscustomobject]@{ N='tail <file> [n]'; D='Last n lines of a file (default 10)' }
        )
        'Navigation' = @(
            [pscustomobject]@{ N='docs';            D='cd to ~\Documents' }
            [pscustomobject]@{ N='down';            D='cd to ~\Downloads' }
            [pscustomobject]@{ N='dtop';            D='cd to ~\Desktop' }
        )
        'Network' = @(
            [pscustomobject]@{ N='Get-PubIP';       D='Show your public IP address' }
            [pscustomobject]@{ N='flushdns';        D='Clear the DNS client cache' }
        )
        'System' = @(
            [pscustomobject]@{ N='uptime';          D='Time since last boot' }
            [pscustomobject]@{ N='sysinfo';         D='Full computer info (Get-ComputerInfo)' }
            [pscustomobject]@{ N='df';              D='List volumes / free space' }
            [pscustomobject]@{ N='reload-profile';  D='Re-run this profile in the current session' }
        )
        'Text Processing' = @(
            [pscustomobject]@{ N='grep <pat> [dir]';D='Search text (Select-String); -i = case-insensitive' }
            [pscustomobject]@{ N='sed <f> <a> <b>'; D='In-place find/replace in a file' }
        )
        'Processes' = @(
            [pscustomobject]@{ N='which <name>';    D='Show the full path/definition of a command' }
            [pscustomobject]@{ N='export <n> <v>';  D='Set an environment variable for this session' }
            [pscustomobject]@{ N='pgrep <name>';    D='List processes matching a name' }
            [pscustomobject]@{ N='pkill <name>';    D='Stop processes matching a name' }
            [pscustomobject]@{ N='k9 <name>';       D='Force-stop a process by name' }
        )
        'Clipboard' = @(
            [pscustomobject]@{ N='cpy <text>';      D='Copy text to the clipboard' }
            [pscustomobject]@{ N='pst';             D='Paste (print) clipboard contents' }
        )
        'Git' = @(
            [pscustomobject]@{ N='gs';              D='git status' }
            [pscustomobject]@{ N='ga';              D='git add .' }
            [pscustomobject]@{ N='gc <msg>';        D='git commit -m <msg>' }
            [pscustomobject]@{ N='gp';              D='git push' }
            [pscustomobject]@{ N='g';               D='Jump to your GitHub dir (zoxide: z Github)' }
            [pscustomobject]@{ N='gcom <msg>';      D='git add . + commit -m <msg>' }
            [pscustomobject]@{ N='lazyg <msg>';     D='git add . + commit + push' }
        )
        'Directory Listing' = @(
            [pscustomobject]@{ N='la';              D='List all items incl. hidden (table)' }
            [pscustomobject]@{ N='ll';              D='List only hidden items (table)' }
        )
    }

    Write-Host ""
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host "  Profile Cheatsheet" -ForegroundColor Cyan
    Write-Host $sep -ForegroundColor DarkCyan

    foreach ($cat in $categories.Keys) {
        Write-Host ""
        Write-Host ("  {0}" -f $cat) -ForegroundColor Yellow
        foreach ($e in $categories[$cat]) {
            Write-Host ("    {0,-18}" -f $e.N) -ForegroundColor White -NoNewline
            Write-Host (" {0}" -f $e.D) -ForegroundColor DarkGray
        }
    }

    Write-Host ""
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host "  Tip: 'Show-FieldTools' lists field tools and profile built-ins." -ForegroundColor DarkGray
    Write-Host ""
}

function Show-FieldTools {
    <#
    .SYNOPSIS
        Banner of field tools loaded from the toolkit folder, plus profile
        built-ins listed in $script:ProfileBuiltins. Synopsis via Get-Help.
    .PARAMETER Detailed
        Also list each function's parameters (non-common only).
    #>
    [CmdletBinding()]
    param([switch]$Detailed)

    $commonParams = @('Verbose','Debug','ErrorAction','WarningAction','InformationAction',
                      'ErrorVariable','WarningVariable','InformationVariable','OutVariable',
                      'OutBuffer','PipelineVariable','ProgressAction')

    # Shared renderer: name + first line of .SYNOPSIS, truncated to fit one line.
    function Write-ToolLine {
        param([string]$Name)
        $cmd = Get-Command $Name -ErrorAction SilentlyContinue
        if (-not $cmd) { return }

        $synopsis = (Get-Help $Name -ErrorAction SilentlyContinue).Synopsis
        $nameRx = [regex]::Escape($Name)
        if (-not $synopsis -or $synopsis -match '^\s*$' -or
            $synopsis -match "^\s*$nameRx(\s|$|\[|<)") {
            $synopsis = '(no .SYNOPSIS)'
        }
        $synopsis = (($synopsis -split "`r?`n" |
            Where-Object { $_.Trim() } | Select-Object -First 1)).Trim()
        $maxLen = 76 - 30
        if ($synopsis.Length -gt $maxLen) {
            $synopsis = $synopsis.Substring(0, $maxLen - 1) + '…'
        }

        Write-Host ("  {0,-28}" -f $Name) -ForegroundColor White -NoNewline
        Write-Host (" {0}" -f $synopsis) -ForegroundColor DarkGray

        if ($Detailed) {
            $params = $cmd.Parameters.Keys | Where-Object { $_ -notin $commonParams }
            if ($params) {
                Write-Host ("      -{0}" -f ($params -join ' -')) -ForegroundColor DarkCyan
            }
        }
    }

    $sep = '─' * 76

    # ── Toolkit folder tools ──────────────────────────────────────────────
    if ($FieldToolsPath -and (Test-Path $FieldToolsPath)) {
        $files = Get-ChildItem -Path $FieldToolsPath -Filter *.ps1 -ErrorAction SilentlyContinue
        if ($files) {
            Write-Host ""
            Write-Host $sep -ForegroundColor DarkCyan
            Write-Host ("  Field Tools  ({0} file{1} from {2})" -f
                $files.Count, $(if ($files.Count -eq 1) { '' } else { 's' }), $FieldToolsPath) -ForegroundColor Cyan
            Write-Host $sep -ForegroundColor DarkCyan

            foreach ($file in $files) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                    $file.FullName, [ref]$null, [ref]$null)
                $funcs = @($ast.EndBlock.Statements |
                    Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
                foreach ($f in $funcs) { Write-ToolLine -Name $f.Name }
            }
        }
    } elseif (-not $env:PROFILE_QUIET) {
        Write-Host ""
        Write-Host "  No toolkit folder found." -ForegroundColor Yellow
        Write-Host "  Set one with: setx PROFILE_TOOLKIT_PATH '<path>'  (or use <OneDrive>\Tools)" -ForegroundColor DarkGray
    }

    # ── Profile built-ins ─────────────────────────────────────────────────
    if ($script:ProfileBuiltins) {
        Write-Host ""
        Write-Host $sep -ForegroundColor DarkCyan
        Write-Host "  Profile Built-ins" -ForegroundColor Cyan
        Write-Host $sep -ForegroundColor DarkCyan
        foreach ($name in $script:ProfileBuiltins) { Write-ToolLine -Name $name }
    }

    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host "  Run any tool with -? for full help. 'Show-FieldTools -Detailed' for params." -ForegroundColor DarkGray
    Write-Host ""
}

# Load toolkit tools (if a folder was resolved), then render the banner.
# The banner always shows the Profile Built-ins section — even on a machine
# with no toolkit folder — so Update-PowerShell and Show-ProfileTools stay
# discoverable everywhere. Set PROFILE_QUIET=1 to suppress the banner.
if ($FieldToolsPath) {
    Get-ChildItem -Path $FieldToolsPath -Filter *.ps1 -ErrorAction SilentlyContinue |
        ForEach-Object {
            Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
            . $_.FullName 6>$null
        }
}

if (-not $env:PROFILE_QUIET) { Show-FieldTools }