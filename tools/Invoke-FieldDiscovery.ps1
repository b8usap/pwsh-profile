<#
.SYNOPSIS
    Field network discovery toolkit for onsite surveys without controller access.

.DESCRIPTION
    Dot-source this file in PowerShell to load the discovery functions:
        . .\Invoke-FieldDiscovery.ps1

    This script auto-sources Update-OuiDatabase.ps1 (sibling file) so vendor
    lookup works offline against the local oui.json database with zero
    network dependency. The previous "alphabetical override" mechanism is
    gone — there is exactly one Add-MacVendor in scope, and it does the
    right thing.

    Requires PowerShell 7+ for parallel pings. Falls back to serial on 5.1.

.EXAMPLE
    # Full discovery on a client's network, export to CSV:
    Invoke-FieldDiscovery -Subnet 10.200.10 -OutputCsv .\client-inventory.csv

.EXAMPLE
    # Individual steps:
    Invoke-PingSweep -Subnet 10.200.10
    Get-ArpInventory -Subnet 10.200.10 | Format-Table
    Get-ArpInventory -Subnet 10.200.10 | Add-MacVendor | Export-Csv inv.csv -NoTypeInformation

.NOTES
    Author:  Steve Pope
    Purpose: Network discovery when UniFi controller credentials are lost
             and a full picture of the existing LAN is needed before cutover.
#>

# ── Auto-source the OUI helpers (sibling file) ───────────────────────────────
# Provides: Get-OuiDatabaseObject, ConvertTo-OuiPrefix, Get-OuiVendor,
#          Update-OuiDatabase, Test-OuiDatabase, Add-OuiEntry, Remove-OuiEntry
# Without this, the offline OUI lookup is unavailable and Add-MacVendor
# degrades gracefully (returns "Unknown" unless -AllowOnline is set).

$script:OuiHelperPath = Join-Path $PSScriptRoot 'Update-OuiDatabase.ps1'
if (Test-Path $script:OuiHelperPath) {
    . $script:OuiHelperPath
} else {
    Write-Warning "Update-OuiDatabase.ps1 not found at $script:OuiHelperPath. Offline vendor lookup unavailable."
}

function Invoke-PingSweep {
    <#
    .SYNOPSIS
        Pings every host in a /24 subnet to populate the local ARP cache.

    .PARAMETER Subnet
        First three octets of the target /24, e.g. "10.200.10" (no trailing dot).

    .PARAMETER TimeoutSeconds
        Per-host ping timeout. Default 1 second.

    .EXAMPLE
        Invoke-PingSweep -Subnet 10.200.10
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Subnet,
        [int] $TimeoutSeconds = 1
    )

    Write-Host "Ping-sweeping $Subnet.1-254 ..." -ForegroundColor Cyan

    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $live = 1..254 | ForEach-Object -Parallel {
            $ip = "$using:Subnet.$_"
            if (Test-Connection -ComputerName $ip -Count 1 -Quiet -TimeoutSeconds $using:TimeoutSeconds) {
                $ip
            }
        } -ThrottleLimit 64
    } else {
        $live = foreach ($i in 1..254) {
            $ip = "$Subnet.$i"
            if (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                $ip
            }
        }
    }

    Write-Host ("  Found {0} live host(s) responding to ICMP." -f @($live).Count) -ForegroundColor Green
    Write-Host "  Note: many devices (DVRs, IoT, printers) drop ping. The ARP cache" -ForegroundColor DarkGray
    Write-Host "  populated below is the more complete picture." -ForegroundColor DarkGray
    return $live
}

function Get-ArpInventory {
    <#
    .SYNOPSIS
        Reads the ARP cache and returns IP/MAC pairs for a given subnet.

    .PARAMETER Subnet
        First three octets of the /24 to filter on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Subnet
    )

    $pattern = "^\s*(?<ip>$([regex]::Escape($Subnet))\.\d{1,3})\s+(?<mac>[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5})\s+(?<type>\w+)"

    arp -a | ForEach-Object {
        if ($_ -match $pattern) {
            [PSCustomObject]@{
                IP   = $Matches.ip
                MAC  = ($Matches.mac -replace '-',':').ToLower()
                Type = $Matches.type
            }
        }
    } | Sort-Object { [version]($_.IP) }
}

function Get-LocalNetworkInfo {
    <#
    .SYNOPSIS
        Reports the laptop's current IP, gateway, DNS, and DHCP server.
        Useful as the first step onsite to confirm what subnet you've landed on.
    #>
    Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' } |
        ForEach-Object {
            [PSCustomObject]@{
                Interface  = $_.InterfaceAlias
                IPv4       = ($_.IPv4Address.IPAddress -join ', ')
                Gateway    = ($_.IPv4DefaultGateway.NextHop -join ', ')
                DNS        = ($_.DNSServer | Where-Object AddressFamily -eq 2 |
                              Select-Object -ExpandProperty ServerAddresses) -join ', '
                MAC        = $_.NetAdapter.MacAddress
                LinkSpeed  = $_.NetAdapter.LinkSpeed
            }
        }
}

function Add-MacVendor {
    <#
    .SYNOPSIS
        Adds a Vendor column to ARP inventory.
        Offline-first: uses local oui.json database. Optionally falls back
        to macvendors.com for OUIs not in the local database.

    .PARAMETER AllowOnline
        Enable macvendors.com fallback for OUIs not found offline.
        Default: off — purely offline operation, safe for mid-cutover use
        when WAN may be unstable.

    .PARAMETER ShowSource
        Adds a Source column ('custom', 'ieee', 'online', 'unknown', 'no-db')
        showing where each match came from. Useful for verifying DB freshness.

    .EXAMPLE
        # Pure offline lookup, no network calls:
        Get-ArpInventory -Subnet 10.200.10 | Add-MacVendor

    .EXAMPLE
        # Offline first, fall back to macvendors.com for misses:
        Get-ArpInventory -Subnet 10.200.10 | Add-MacVendor -AllowOnline

    .EXAMPLE
        # Show where each lookup came from (sanity check for db freshness):
        Get-ArpInventory -Subnet 10.200.10 | Add-MacVendor -ShowSource | Format-Table
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)] $InputObject,
        [switch] $AllowOnline,
        [switch] $ShowSource
    )
    begin {
        $hasOfflineDb = $null -ne (Get-Command Get-OuiDatabaseObject -ErrorAction SilentlyContinue)
        $db = if ($hasOfflineDb) { Get-OuiDatabaseObject } else { $null }
        $onlineCache = @{}

        if (-not $hasOfflineDb) {
            Write-Warning "Update-OuiDatabase.ps1 not loaded. Vendor lookup will be 'Unknown' unless -AllowOnline is set."
        } elseif (-not $db) {
            Write-Warning "Offline OUI database not found. Run Update-OuiDatabase, or use -AllowOnline."
        }
    }
    process {
        $mac    = $InputObject.MAC
        $oui    = if ($hasOfflineDb) { try { ConvertTo-OuiPrefix $mac } catch { $null } } else { $null }
        $vendor = $null
        $source = 'unknown'

        # Offline lookup first
        if ($oui -and $db) {
            if ($db.Custom.ContainsKey($oui))      { $vendor = $db.Custom[$oui];  $source = 'custom' }
            elseif ($db.Entries.ContainsKey($oui)) { $vendor = $db.Entries[$oui]; $source = 'ieee'   }
        }

        # Online fallback (only if explicitly enabled)
        if (-not $vendor -and $AllowOnline -and $mac) {
            $cacheKey = if ($oui) { $oui } else { $mac }
            if ($onlineCache.ContainsKey($cacheKey)) {
                $vendor = $onlineCache[$cacheKey]
                if ($vendor) { $source = 'online' }
            } else {
                try {
                    $vendor = Invoke-RestMethod -Uri "https://api.macvendors.com/$mac" `
                        -TimeoutSec 5 -ErrorAction Stop
                    $source = 'online'
                } catch {
                    $vendor = $null
                }
                $onlineCache[$cacheKey] = $vendor
                Start-Sleep -Milliseconds 600  # macvendors.com rate limit
            }
        }

        # Final status if still empty
        if (-not $vendor -and -not $hasOfflineDb) { $source = 'no-db' }

        $out = $InputObject | Add-Member -NotePropertyName Vendor `
            -NotePropertyValue ($vendor ?? 'Unknown') -PassThru
        if ($ShowSource) {
            $out = $out | Add-Member -NotePropertyName Source `
                -NotePropertyValue $source -PassThru
        }
        $out
    }
}

function Invoke-FieldDiscovery {
    <#
    .SYNOPSIS
        Single-shot orchestrator: local info -> ping sweep -> ARP -> vendor lookup -> CSV.

    .PARAMETER Subnet
        First three octets, e.g. "10.200.10".

    .PARAMETER OutputCsv
        Optional path to write the inventory as CSV.

    .PARAMETER SkipVendor
        Skip vendor lookup entirely (faster, no Vendor column).

    .PARAMETER AllowOnline
        Allow online fallback to macvendors.com for OUIs not in offline db.

    .PARAMETER ShowSource
        Include a Source column showing where each vendor match came from.

    .EXAMPLE
        Invoke-FieldDiscovery -Subnet 10.200.10 -OutputCsv .\inventory.csv

    .EXAMPLE
        # With source tracking, to verify offline db is being used:
        Invoke-FieldDiscovery -Subnet 10.200.10 -ShowSource
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Subnet,
        [string] $OutputCsv,
        [switch] $SkipVendor,
        [switch] $AllowOnline,
        [switch] $ShowSource
    )

    Write-Host "`n=== Local network configuration ===" -ForegroundColor Yellow
    Get-LocalNetworkInfo | Format-List

    Write-Host "`n=== Step 1: populate ARP via ping sweep ===" -ForegroundColor Yellow
    Invoke-PingSweep -Subnet $Subnet | Out-Null

    Write-Host "`n=== Step 2: read ARP cache for $Subnet.0/24 ===" -ForegroundColor Yellow
    $inv = Get-ArpInventory -Subnet $Subnet

    if (-not $SkipVendor) {
        $modeText = if ($AllowOnline) { 'offline first, online fallback' } else { 'offline only' }
        Write-Host "`n=== Step 3: OUI vendor lookup ($modeText) ===" -ForegroundColor Yellow
        $inv = $inv | Add-MacVendor -AllowOnline:$AllowOnline -ShowSource:$ShowSource
    }

    Write-Host "`n=== Inventory ===" -ForegroundColor Yellow
    $inv | Format-Table -AutoSize

    if ($OutputCsv) {
        $inv | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
        Write-Host "`nWrote $($inv.Count) record(s) to $OutputCsv" -ForegroundColor Green
    }

    return $inv
}

# ── Banner when dot-sourced ──────────────────────────────────────────────────
Write-Host ""
Write-Host "Field Discovery Toolkit loaded." -ForegroundColor Cyan
Write-Host "Available commands:" -ForegroundColor Cyan
Write-Host "  Get-LocalNetworkInfo                              # what subnet am I on?"
Write-Host "  Invoke-PingSweep    -Subnet 10.200.10             # populate ARP cache"
Write-Host "  Get-ArpInventory    -Subnet 10.200.10             # read ARP, IP/MAC pairs"
Write-Host "  Add-MacVendor                                     # pipe ARP through OUI lookup"
Write-Host "  Invoke-FieldDiscovery -Subnet 10.200.10 -OutputCsv .\inv.csv   # full run"
Write-Host ""
if (Get-Command Test-FieldToolkit -ErrorAction SilentlyContinue) {
    Write-Host "  Test-FieldToolkit                                 # verify everything is wired up" -ForegroundColor DarkGray
    Write-Host ""
}
