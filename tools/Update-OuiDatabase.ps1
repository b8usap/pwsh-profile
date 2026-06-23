<#
.SYNOPSIS
    Offline OUI (MAC vendor) database for field discovery — local lookup that
    works mid-cutover when WAN is down, updateable from IEEE when online.

.DESCRIPTION
    The IEEE publishes the canonical OUI registry as a CSV at
    https://standards-oui.ieee.org/oui/oui.csv. This script:

      1. Downloads and parses that CSV into a compact JSON file.
      2. Provides offline-first vendor lookup against that JSON.
      3. Supports custom client-specific entries that survive IEEE updates.

    The OUI database file (oui.json, ~2 MB) lives alongside the scripts.
    Path resolution order:
      1. $env:PROFILE_TOOLKIT_PATH (if set) → $env:PROFILE_TOOLKIT_PATH\oui.json
      2. $PSScriptRoot\oui.json (the directory this script lives in)

    Set $env:PROFILE_TOOLKIT_PATH once per machine to support running this
    toolkit from your PowerShell profile regardless of where the scripts
    live (typically your OneDrive Tools folder).

    Note: Add-MacVendor is now defined in Invoke-FieldDiscovery.ps1 — this
    file is no longer in the override business. Load order doesn't matter.

.EXAMPLE
    # One-time setup on any laptop with internet:
    Update-OuiDatabase

.EXAMPLE
    # Single lookup:
    Get-OuiVendor -Mac 'fc:fc:48:12:34:56'

.EXAMPLE
    # Add a custom entry that survives IEEE updates:
    Add-OuiEntry -Mac 'aa:bb:cc' -Vendor 'Client X NVR'

.EXAMPLE
    # Database stats and toolkit health check:
    Test-OuiDatabase
    Test-FieldToolkit
#>

# ── Storage path resolution ──────────────────────────────────────────────────
# Prefer $env:PROFILE_TOOLKIT_PATH (set once per machine, points at your toolkit
# folder, usually OneDrive\Tools). Falls back to $PSScriptRoot (the directory
# this script lives in) for dot-sourced standalone use.

$script:OuiPath = if ($env:PROFILE_TOOLKIT_PATH -and (Test-Path $env:PROFILE_TOOLKIT_PATH)) {
    Join-Path $env:PROFILE_TOOLKIT_PATH 'oui.json'
} elseif ($PSScriptRoot) {
    Join-Path $PSScriptRoot 'oui.json'
} else {
    # Last-resort fallback if this gets evaluated outside a script context
    Join-Path (Get-Location) 'oui.json'
}

$script:OuiCache = $null   # in-memory hashtable cache, loaded lazily
$script:OuiUrl   = 'https://standards-oui.ieee.org/oui/oui.csv'

# ── Private: lazy-load the database into memory ──────────────────────────────

function Get-OuiDatabaseObject {
    [CmdletBinding()]
    param([switch] $Force)

    if ($script:OuiCache -and -not $Force) { return $script:OuiCache }

    if (-not (Test-Path $script:OuiPath)) {
        return $null
    }

    try {
        $json = Get-Content $script:OuiPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # ConvertFrom-Json returns PSCustomObject; convert entries to hashtable
        # for O(1) lookups and case-insensitive key handling.
        $entries = @{}
        if ($json.entries) {
            foreach ($prop in $json.entries.PSObject.Properties) {
                $entries[$prop.Name] = $prop.Value
            }
        }
        $custom = @{}
        if ($json.custom) {
            foreach ($prop in $json.custom.PSObject.Properties) {
                $custom[$prop.Name] = $prop.Value
            }
        }
        $script:OuiCache = [PSCustomObject]@{
            Meta    = $json._meta
            Entries = $entries
            Custom  = $custom
            Path    = $script:OuiPath
        }
        return $script:OuiCache
    } catch {
        Write-Warning "Could not parse OUI database at $($script:OuiPath): $_"
        return $null
    }
}

# ── Private: normalize a MAC to a 6-char uppercase OUI prefix ────────────────

function ConvertTo-OuiPrefix {
    param([Parameter(Mandatory)] [string] $Mac)
    $clean = ($Mac -replace '[^0-9a-fA-F]','').ToUpper()
    if ($clean.Length -lt 6) {
        throw "MAC '$Mac' too short — need at least 6 hex digits for an OUI prefix."
    }
    return $clean.Substring(0,6)
}

# ── Public: download and rebuild the database ────────────────────────────────

function Update-OuiDatabase {
    <#
    .SYNOPSIS
        Downloads the IEEE OUI registry and rebuilds the local database.

    .DESCRIPTION
        Pulls oui.csv from standards-oui.ieee.org, parses it, and writes a
        compact JSON file. Custom entries (added via Add-OuiEntry) are
        preserved across updates.

    .PARAMETER Path
        Override the default database location.

    .PARAMETER Source
        Override the IEEE URL. Useful if you're behind a proxy that mirrors
        the IEEE feed internally.

    .EXAMPLE
        Update-OuiDatabase
    #>
    [CmdletBinding()]
    param(
        [string] $Path = $script:OuiPath,
        [string] $Source = $script:OuiUrl
    )

    # Preserve existing custom entries
    $existingCustom = @{}
    if (Test-Path $Path) {
        try {
            $existing = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($existing.custom) {
                foreach ($prop in $existing.custom.PSObject.Properties) {
                    $existingCustom[$prop.Name] = $prop.Value
                }
            }
        } catch { }
    }

    Write-Host "Downloading IEEE OUI registry from $Source ..." -ForegroundColor Cyan
    $temp = New-TemporaryFile
    try {
        Invoke-WebRequest -Uri $Source -OutFile $temp -UseBasicParsing -TimeoutSec 60
        $sizeKB = [math]::Round((Get-Item $temp).Length / 1KB, 1)
        Write-Host "  Downloaded $sizeKB KB" -ForegroundColor Green

        Write-Host "Parsing CSV ..." -ForegroundColor Cyan
        # CSV columns: Registry,Assignment,Organization Name,Organization Address
        # We only care about MA-L (24-bit OUI) entries since that's 99%+ of
        # real-world MAC prefixes. MA-M and MA-S use longer prefixes and
        # would need different lookup logic.
        $csv = Import-Csv -Path $temp
        $entries = @{}
        foreach ($row in $csv) {
            if ($row.Registry -ne 'MA-L') { continue }
            $oui = ($row.Assignment -as [string]).ToUpper()
            if ($oui -and $oui.Length -eq 6) {
                $entries[$oui] = $row.'Organization Name'.Trim()
            }
        }

        Write-Host "  Parsed $($entries.Count) MA-L entries" -ForegroundColor Green

        # Compose final structure
        $output = [PSCustomObject]@{
            _meta = [PSCustomObject]@{
                source     = $Source
                downloaded = (Get-Date).ToString('s')
                count      = $entries.Count
                customCount= $existingCustom.Count
            }
            entries = $entries
            custom  = $existingCustom
        }

        Write-Host "Writing $Path ..." -ForegroundColor Cyan
        $output | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $Path -Encoding UTF8
        $sizeKB = [math]::Round((Get-Item $Path).Length / 1KB, 1)
        Write-Host "  Wrote $sizeKB KB ($($entries.Count) IEEE entries, $($existingCustom.Count) custom)" -ForegroundColor Green

        # Invalidate cache so next lookup loads fresh data
        $script:OuiCache = $null

    } finally {
        Remove-Item $temp -ErrorAction SilentlyContinue
    }
}

# ── Public: single-MAC lookup ────────────────────────────────────────────────

function Get-OuiVendor {
    <#
    .SYNOPSIS
        Looks up a MAC address against the local OUI database.

    .PARAMETER Mac
        MAC address in any common format: 'aa:bb:cc:dd:ee:ff', 'AA-BB-CC-DD-EE-FF',
        'AABBCCDDEEFF', or just the 6-char OUI 'AABBCC'.

    .PARAMETER IncludeMeta
        Return a detailed object showing whether the match came from custom
        entries or the IEEE registry.

    .EXAMPLE
        Get-OuiVendor -Mac 'fc:fc:48:12:34:56'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [string] $Mac,
        [switch] $IncludeMeta
    )
    process {
        $db = Get-OuiDatabaseObject
        if (-not $db) {
            if ($IncludeMeta) {
                return [PSCustomObject]@{ Mac = $Mac; Vendor = $null; Source = 'no-database' }
            }
            return $null
        }

        $oui = ConvertTo-OuiPrefix $Mac

        # Custom entries take priority
        if ($db.Custom.ContainsKey($oui)) {
            if ($IncludeMeta) {
                return [PSCustomObject]@{ Mac = $Mac; OuiPrefix = $oui; Vendor = $db.Custom[$oui]; Source = 'custom' }
            }
            return $db.Custom[$oui]
        }

        if ($db.Entries.ContainsKey($oui)) {
            if ($IncludeMeta) {
                return [PSCustomObject]@{ Mac = $Mac; OuiPrefix = $oui; Vendor = $db.Entries[$oui]; Source = 'ieee' }
            }
            return $db.Entries[$oui]
        }

        if ($IncludeMeta) {
            return [PSCustomObject]@{ Mac = $Mac; OuiPrefix = $oui; Vendor = $null; Source = 'not-found' }
        }
        return $null
    }
}

# ── Public: stats about the database ─────────────────────────────────────────

function Test-OuiDatabase {
    <#
    .SYNOPSIS
        Reports on the local OUI database: location, age, entry counts.
    #>
    [CmdletBinding()] param()

    if (-not (Test-Path $script:OuiPath)) {
        Write-Host ""
        Write-Host "OUI database not found." -ForegroundColor Yellow
        Write-Host "  Expected: $script:OuiPath" -ForegroundColor DarkGray
        Write-Host "  Run: Update-OuiDatabase" -ForegroundColor DarkGray
        Write-Host ""
        return
    }

    $db = Get-OuiDatabaseObject -Force
    if (-not $db) { return }

    $file = Get-Item $script:OuiPath
    $ageDays = [math]::Round(((Get-Date) - [datetime]$db.Meta.downloaded).TotalDays, 1)

    Write-Host ""
    Write-Host "OUI Database" -ForegroundColor Cyan
    Write-Host "  Path:        $script:OuiPath"
    Write-Host "  Size:        $([math]::Round($file.Length / 1KB, 1)) KB"
    Write-Host "  Downloaded:  $($db.Meta.downloaded) ($ageDays days ago)"
    Write-Host "  Source:      $($db.Meta.source)"
    Write-Host "  IEEE entries:    $($db.Entries.Count)"
    Write-Host "  Custom entries:  $($db.Custom.Count)"
    if ($db.Custom.Count -gt 0) {
        Write-Host ""
        Write-Host "  Custom entries:" -ForegroundColor DarkGray
        foreach ($k in $db.Custom.Keys | Sort-Object) {
            Write-Host "    $k -> $($db.Custom[$k])" -ForegroundColor DarkGray
        }
    }
    if ($ageDays -gt 30) {
        Write-Host ""
        Write-Host "  [!!] Database is $ageDays days old. Consider: Update-OuiDatabase" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ── Public: end-to-end toolkit health check ──────────────────────────────────

function Test-FieldToolkit {
    <#
    .SYNOPSIS
        End-to-end sanity check of the Field Discovery toolkit.

    .DESCRIPTION
        Verifies all required functions are loaded, the OUI database is
        present and parseable, and a known OUI lookup actually returns the
        expected vendor. Useful as the first command of any onsite engagement.

    .EXAMPLE
        Test-FieldToolkit
    #>
    [CmdletBinding()] param()

    Write-Host ""
    Write-Host "Field Toolkit Health Check" -ForegroundColor Cyan
    Write-Host ("─" * 50) -ForegroundColor DarkGray

    $allOk = $true

    # 1. Required functions present
    $required = @(
        'Get-LocalNetworkInfo','Invoke-PingSweep','Get-ArpInventory',
        'Add-MacVendor','Invoke-FieldDiscovery',
        'Update-OuiDatabase','Get-OuiVendor','Test-OuiDatabase',
        'Add-OuiEntry','Remove-OuiEntry',
        'ConvertTo-OuiPrefix','Get-OuiDatabaseObject'
    )
    foreach ($fn in $required) {
        $present = $null -ne (Get-Command $fn -ErrorAction SilentlyContinue)
        $mark = if ($present) { '[OK]' } else { '[--]' }
        $color = if ($present) { 'Green' } else { 'Red' }
        Write-Host ("  {0} {1}" -f $mark, $fn) -ForegroundColor $color
        if (-not $present) { $allOk = $false }
    }

    Write-Host ""

    # 2. Toolkit path
    if ($env:PROFILE_TOOLKIT_PATH) {
        Write-Host "  [OK] PROFILE_TOOLKIT_PATH = $env:PROFILE_TOOLKIT_PATH" -ForegroundColor Green
    } else {
        Write-Host "  [--] PROFILE_TOOLKIT_PATH not set (using `$PSScriptRoot fallback)" -ForegroundColor Yellow
        Write-Host "       To set: setx PROFILE_TOOLKIT_PATH '<your toolkit path>'" -ForegroundColor DarkGray
    }

    # 3. OUI database
    if (Test-Path $script:OuiPath) {
        $file = Get-Item $script:OuiPath
        Write-Host ("  [OK] OUI database present: {0} ({1} KB)" -f `
            $script:OuiPath, [math]::Round($file.Length / 1KB, 0)) -ForegroundColor Green
    } else {
        Write-Host "  [--] OUI database missing at $script:OuiPath" -ForegroundColor Red
        Write-Host "       To fix: Update-OuiDatabase" -ForegroundColor DarkGray
        $allOk = $false
    }

    # 4. Known-good lookup test
    if (Test-Path $script:OuiPath) {
        try {
            $testMac = 'a8:9c:6c:00:00:00'    # Ubiquiti
            $result  = Get-OuiVendor -Mac $testMac
            if ($result -match 'Ubiquiti') {
                Write-Host "  [OK] Test lookup: $testMac → $result" -ForegroundColor Green
            } elseif ($result) {
                Write-Host "  [??] Test lookup: $testMac → $result (expected Ubiquiti)" -ForegroundColor Yellow
            } else {
                Write-Host "  [--] Test lookup: $testMac → no vendor returned" -ForegroundColor Red
                $allOk = $false
            }
        } catch {
            Write-Host "  [--] Test lookup threw exception: $_" -ForegroundColor Red
            $allOk = $false
        }
    }

    Write-Host ("─" * 50) -ForegroundColor DarkGray
    if ($allOk) {
        Write-Host "  All checks passed. Toolkit ready." -ForegroundColor Green
    } else {
        Write-Host "  One or more checks failed. See messages above." -ForegroundColor Yellow
    }
    Write-Host ""
}

# ── Public: manage custom entries ────────────────────────────────────────────

function Add-OuiEntry {
    <#
    .SYNOPSIS
        Adds (or replaces) a custom OUI->vendor mapping. Survives IEEE updates.

    .PARAMETER Mac
        MAC or OUI prefix. Only the first 6 hex chars are used.

    .PARAMETER Vendor
        Vendor / device label to associate with that prefix.

    .EXAMPLE
        Add-OuiEntry -Mac 'aa:bb:cc:dd:ee:ff' -Vendor 'Client X NVR'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Mac,
        [Parameter(Mandatory)] [string] $Vendor
    )

    if (-not (Test-Path $script:OuiPath)) {
        throw "OUI database not found. Run Update-OuiDatabase first."
    }

    $oui = ConvertTo-OuiPrefix $Mac
    $raw = Get-Content $script:OuiPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable

    if (-not $raw.custom) { $raw.custom = @{} }
    $raw.custom[$oui] = $Vendor
    $raw._meta.customCount = $raw.custom.Count

    $raw | ConvertTo-Json -Depth 4 -Compress | Set-Content $script:OuiPath -Encoding UTF8
    $script:OuiCache = $null   # invalidate
    Write-Host "Added custom: $oui -> $Vendor" -ForegroundColor Green
}

function Remove-OuiEntry {
    <#
    .SYNOPSIS
        Removes a custom OUI mapping. IEEE entries cannot be removed (they're
        rebuilt from source on Update-OuiDatabase).

    .EXAMPLE
        Remove-OuiEntry -Mac 'aa:bb:cc'
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Mac)

    if (-not (Test-Path $script:OuiPath)) {
        throw "OUI database not found."
    }

    $oui = ConvertTo-OuiPrefix $Mac
    $raw = Get-Content $script:OuiPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable

    if ($raw.custom -and $raw.custom.ContainsKey($oui)) {
        $raw.custom.Remove($oui) | Out-Null
        $raw._meta.customCount = $raw.custom.Count
        $raw | ConvertTo-Json -Depth 4 -Compress | Set-Content $script:OuiPath -Encoding UTF8
        $script:OuiCache = $null
        Write-Host "Removed custom: $oui" -ForegroundColor Green
    } else {
        Write-Host "No custom entry for $oui (IEEE entries cannot be removed)." -ForegroundColor Yellow
    }
}
