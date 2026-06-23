<#
.SYNOPSIS
    LTS / Hikvision DVR & NVR config puller — talks to the device's ISAPI HTTP
    API to retrieve network configuration, channel inventory, attached IP
    cameras, and port assignments without walking on-device menus.

.DESCRIPTION
    LTS DVRs (LTD83XXK-ET, LTD85XXK-ST, etc.) are Hikvision OEM products and
    expose the standard Hikvision ISAPI on their HTTP port (default 80).
    This toolkit uses HTTP Digest authentication to pull XML responses from
    a handful of useful endpoints and normalizes them into PSCustomObjects.

    Use this onsite during discovery to capture the existing DVR config
    before factory reset, or post-cutover to verify the device landed on
    the right subnet and is reachable from the household VLAN.

    Requires PowerShell 7+ (uses -Authentication Digest in Invoke-RestMethod).

.EXAMPLE
    # Quick connection test:
    Test-DvrConnection -IpAddress 10.200.10.50

.EXAMPLE
    # Full config dump, prompts for admin credentials:
    Get-DvrConfig -IpAddress 10.200.10.50

.EXAMPLE
    # Dump to a JSON file for migration documentation:
    Get-DvrConfig -IpAddress 10.200.10.50 -OutputPath .\dvr-pre-cutover.json

.EXAMPLE
    # Save creds once, reuse for multiple calls:
    $cred = Get-Credential -UserName admin -Message "DVR admin"
    Get-DvrConfig -IpAddress 10.200.10.50 -Credential $cred | Show-DvrConfig
    Test-DvrConnection -IpAddress 10.200.10.50 -Credential $cred

.NOTES
    Tested against: LTS LTD8504K-ST (Hikvision DS-72xx OEM)
    ISAPI reference: https://oversea-download.hikvision.com/uploadfile/Leaflet/ISAPI/HIKVISION%20ISAPI_2.6-IPMD%20Service.pdf
#>

# ── Private helper: ISAPI request with retry on cert/auth quirks ─────────────

function Invoke-DvrIsapi {
    <#
    .SYNOPSIS
        Internal helper. Hits an ISAPI endpoint and returns parsed XML.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $IpAddress,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [int] $Port = 80,
        [switch] $UseHttps,
        [int] $TimeoutSec = 8
    )

    $scheme = if ($UseHttps) { 'https' } else { 'http' }
    $uri    = "${scheme}://${IpAddress}:${Port}${Path}"

    $params = @{
        Uri              = $uri
        Credential       = $Credential
        Authentication   = 'Digest'
        TimeoutSec       = $TimeoutSec
        ErrorAction      = 'Stop'
        UseBasicParsing  = $true
    }
    if ($UseHttps) { $params.SkipCertificateCheck = $true }

    try {
        $raw = Invoke-RestMethod @params
    } catch {
        # Common failure modes — translate to actionable messages
        $msg = $_.Exception.Message
        if ($msg -match '401|Unauthorized') {
            throw "Authentication failed for $uri. Check admin username/password."
        } elseif ($msg -match 'timed out|timeout|unable to connect') {
            throw "Could not reach $uri — DVR offline, wrong IP, or wrong port?"
        } elseif ($msg -match 'SSL|certificate|TLS') {
            throw "TLS error talking to $uri — try without -UseHttps, or the firmware may require HTTPS only."
        } else {
            throw "ISAPI call to $Path failed: $msg"
        }
    }

    # ISAPI returns XML — Invoke-RestMethod auto-parses to [xml] when
    # Content-Type is application/xml. If we got a string back, parse manually.
    if ($raw -is [string]) {
        try   { return [xml]$raw }
        catch { return $raw }
    }
    return $raw
}

# ── Public: lightweight connection test ──────────────────────────────────────

function Test-DvrConnection {
    <#
    .SYNOPSIS
        Verifies the DVR is reachable and admin credentials work.

    .PARAMETER IpAddress
        DVR IP address.

    .PARAMETER Credential
        PSCredential for the admin user. Prompts if not supplied.

    .PARAMETER Port
        HTTP port (default 80). LTS default is 80.

    .PARAMETER UseHttps
        Switch to HTTPS — required for some newer firmware.

    .EXAMPLE
        Test-DvrConnection -IpAddress 10.200.10.50
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $IpAddress,
        [pscredential] $Credential,
        [int] $Port = 80,
        [switch] $UseHttps
    )

    if (-not $Credential) {
        $Credential = Get-Credential -UserName 'admin' -Message "DVR admin credentials for $IpAddress"
    }

    try {
        $info = Invoke-DvrIsapi -IpAddress $IpAddress -Path '/ISAPI/System/deviceInfo' `
            -Credential $Credential -Port $Port -UseHttps:$UseHttps
        Write-Host ""
        Write-Host "[OK] Connected to DVR at ${IpAddress}:${Port}" -ForegroundColor Green
        Write-Host "     Model:    $($info.DeviceInfo.model)"
        Write-Host "     Serial:   $($info.DeviceInfo.serialNumber)"
        Write-Host "     Firmware: $($info.DeviceInfo.firmwareVersion) ($($info.DeviceInfo.firmwareReleasedDate))"
        Write-Host "     MAC:      $($info.DeviceInfo.macAddress)"
        Write-Host ""
        return $true
    } catch {
        Write-Host ""
        Write-Host "[FAIL] $_" -ForegroundColor Red
        Write-Host ""
        return $false
    }
}

# ── Public: full config pull ─────────────────────────────────────────────────

function Get-DvrConfig {
    <#
    .SYNOPSIS
        Pulls network config, channel status, IP cameras, and ports from an
        LTS/Hikvision DVR via ISAPI.

    .PARAMETER IpAddress
        DVR IP address.

    .PARAMETER Credential
        PSCredential for the admin user. Prompts if not supplied.

    .PARAMETER Port
        HTTP port (default 80).

    .PARAMETER UseHttps
        Use HTTPS — required for some newer firmware.

    .PARAMETER OutputPath
        Optional path to write the result as JSON. Useful for the discovery
        checklist record or for diffing pre- vs post-cutover state.

    .EXAMPLE
        Get-DvrConfig -IpAddress 10.200.10.50 -OutputPath .\dvr-config.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $IpAddress,
        [pscredential] $Credential,
        [int] $Port = 80,
        [switch] $UseHttps,
        [string] $OutputPath
    )

    if (-not $Credential) {
        $Credential = Get-Credential -UserName 'admin' -Message "DVR admin credentials for $IpAddress"
    }

    $isapi = @{
        IpAddress  = $IpAddress
        Credential = $Credential
        Port       = $Port
        UseHttps   = $UseHttps
    }

    Write-Host "Pulling config from $IpAddress ..." -ForegroundColor Cyan

    # --- Device info ---
    Write-Host "  -> /ISAPI/System/deviceInfo" -ForegroundColor DarkGray
    $info = (Invoke-DvrIsapi @isapi -Path '/ISAPI/System/deviceInfo').DeviceInfo

    # --- Network interface (IPv4) ---
    Write-Host "  -> /ISAPI/System/Network/interfaces/1/ipAddress" -ForegroundColor DarkGray
    $net = (Invoke-DvrIsapi @isapi -Path '/ISAPI/System/Network/interfaces/1/ipAddress').IPAddress

    # --- Time / NTP ---
    Write-Host "  -> /ISAPI/System/time" -ForegroundColor DarkGray
    $timeXml = Invoke-DvrIsapi @isapi -Path '/ISAPI/System/time'
    $ntp = $null
    try {
        $ntpXml = Invoke-DvrIsapi @isapi -Path '/ISAPI/System/time/ntpServers/1'
        $ntp = $ntpXml.NTPServer
    } catch {
        # NTP endpoint may not be present on all firmwares — non-fatal
    }

    # --- IP cameras (LAN-attached, distinct from analog/TVI BNC inputs) ---
    Write-Host "  -> /ISAPI/ContentMgmt/InputProxy/channels" -ForegroundColor DarkGray
    $ipCams = @()
    try {
        $ipCamXml = Invoke-DvrIsapi @isapi -Path '/ISAPI/ContentMgmt/InputProxy/channels'
        $ipCams = @($ipCamXml.InputProxyChannelList.InputProxyChannel | Where-Object { $_ }) |
            ForEach-Object {
                [PSCustomObject]@{
                    Id           = $_.id
                    Name         = $_.name
                    IpAddress    = $_.sourceInputPortDescriptor.ipAddress
                    Port         = $_.sourceInputPortDescriptor.managePortNo
                    Protocol     = $_.sourceInputPortDescriptor.proxyProtocol
                    SrcInputPort = $_.sourceInputPortDescriptor.srcInputPort
                    UserName     = $_.sourceInputPortDescriptor.userName
                }
            }
    } catch {
        # No IP cameras attached — silent, this is normal for analog-only setups
    }

    # --- Analog/TVI input channels ---
    Write-Host "  -> /ISAPI/System/Video/inputs/channels" -ForegroundColor DarkGray
    $analogChannels = @()
    try {
        $vinXml = Invoke-DvrIsapi @isapi -Path '/ISAPI/System/Video/inputs/channels'
        $analogChannels = @($vinXml.VideoInputChannelList.VideoInputChannel) |
            ForEach-Object {
                [PSCustomObject]@{
                    Id       = $_.id
                    Name     = $_.name
                    InputPort= $_.inputPort
                    Enabled  = if ($_.PSObject.Properties['enabled']) { $_.enabled } else { 'unknown' }
                }
            }
    } catch {
        # Some firmware variants use different path; non-fatal
    }

    # --- Ports (HTTP, RTSP, server) ---
    Write-Host "  -> /ISAPI/Security/extern (ports)" -ForegroundColor DarkGray
    $ports = [PSCustomObject]@{ HTTP = 80; RTSP = 554; Server = 8000; HTTPS = 443 }  # defaults
    try {
        $portXml = Invoke-DvrIsapi @isapi -Path '/ISAPI/Security/extern'
        if ($portXml.ExternList.Extern) {
            foreach ($p in $portXml.ExternList.Extern) {
                switch ($p.serviceType) {
                    'http'   { $ports.HTTP   = [int]$p.serverPort }
                    'rtsp'   { $ports.RTSP   = [int]$p.serverPort }
                    'server' { $ports.Server = [int]$p.serverPort }
                    'https'  { $ports.HTTPS  = [int]$p.serverPort }
                }
            }
        }
    } catch {
        # Use defaults; some firmware exposes ports under /ISAPI/System/Network/extern instead
        try {
            $portXml = Invoke-DvrIsapi @isapi -Path '/ISAPI/System/Network/extern'
            if ($portXml.ExternList.Extern) {
                foreach ($p in $portXml.ExternList.Extern) {
                    switch ($p.serviceType) {
                        'http'   { $ports.HTTP   = [int]$p.serverPort }
                        'rtsp'   { $ports.RTSP   = [int]$p.serverPort }
                        'server' { $ports.Server = [int]$p.serverPort }
                        'https'  { $ports.HTTPS  = [int]$p.serverPort }
                    }
                }
            }
        } catch {
            # Fall back to defaults silently
        }
    }

    # --- Compose result ---
    $result = [PSCustomObject]@{
        CapturedAt = (Get-Date).ToString('s')
        Device = [PSCustomObject]@{
            Model           = $info.model
            Serial          = $info.serialNumber
            Firmware        = $info.firmwareVersion
            FirmwareDate    = $info.firmwareReleasedDate
            MAC             = $info.macAddress
            DeviceName      = $info.deviceName
            DeviceID        = $info.deviceID
        }
        Network = [PSCustomObject]@{
            IpAddress       = $net.ipAddress
            SubnetMask      = $net.subnetMask
            Gateway         = $net.DefaultGateway.ipAddress
            PrimaryDNS      = $net.PrimaryDNS.ipAddress
            SecondaryDNS    = $net.SecondaryDNS.ipAddress
            AddressingType  = $net.addressingType   # 'dynamic' = DHCP, 'static' = manual
            IpVersion       = $net.ipVersion
        }
        Ports = $ports
        Time = [PSCustomObject]@{
            LocalTime       = $timeXml.Time.localTime
            TimeZone        = $timeXml.Time.timeZone
            Mode            = $timeXml.Time.timeMode  # 'NTP' or 'manual'
            NtpServer       = $ntp.hostName
            NtpPort         = $ntp.portNo
            NtpInterval     = $ntp.synchronizeInterval
        }
        AnalogChannels = $analogChannels
        IpCameras      = $ipCams
    }

    Write-Host "  Done." -ForegroundColor Green

    if ($OutputPath) {
        $result | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8
        Write-Host "  Saved JSON to $OutputPath" -ForegroundColor Green
    }

    return $result
}

# ── Public: pretty-print to terminal ─────────────────────────────────────────

function Show-DvrConfig {
    <#
    .SYNOPSIS
        Pretty-prints a DVR config object returned from Get-DvrConfig.

    .EXAMPLE
        Get-DvrConfig -IpAddress 10.200.10.50 | Show-DvrConfig
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $Config
    )
    process {
        Write-Host ""
        Write-Host "=== DVR / NVR Configuration ===" -ForegroundColor Cyan
        Write-Host "Captured: $($Config.CapturedAt)" -ForegroundColor DarkGray
        Write-Host ""

        Write-Host "Device" -ForegroundColor Yellow
        $Config.Device | Format-List | Out-String | Write-Host

        Write-Host "Network" -ForegroundColor Yellow
        $Config.Network | Format-List | Out-String | Write-Host

        Write-Host "Ports" -ForegroundColor Yellow
        $Config.Ports | Format-List | Out-String | Write-Host

        Write-Host "Time / NTP" -ForegroundColor Yellow
        $Config.Time | Format-List | Out-String | Write-Host

        if ($Config.AnalogChannels -and $Config.AnalogChannels.Count -gt 0) {
            Write-Host "Analog/TVI Input Channels ($($Config.AnalogChannels.Count))" -ForegroundColor Yellow
            $Config.AnalogChannels | Format-Table -AutoSize | Out-String | Write-Host
        }

        if ($Config.IpCameras -and $Config.IpCameras.Count -gt 0) {
            Write-Host "LAN-Attached IP Cameras ($($Config.IpCameras.Count))" -ForegroundColor Yellow
            $Config.IpCameras | Format-Table -AutoSize | Out-String | Write-Host
            Write-Host "  Note: these IP cams must move to the DVR VLAN during cutover." -ForegroundColor DarkGray
        } else {
            Write-Host "LAN-Attached IP Cameras: none" -ForegroundColor DarkGray
        }

        Write-Host ""
    }
}
