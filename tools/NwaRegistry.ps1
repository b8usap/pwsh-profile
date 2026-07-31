# NwaRegistry loader — imports the IP/VLAN registry module.
# The .psm1 MUST stay colocated with registry.yaml (source of truth): the
# module resolves the YAML via $PSScriptRoot, so a split copy silently
# serves stale data. Never copy the .psm1 on its own.
# Per-machine override: set NWA_REGISTRY_MODULE to the .psm1 path.
# Provides: Get-Registry, Get-Site, Get-NextSiteId, Find-Address, New-Site,
#           Set-SiteStatus, Test-Registry, Install-RegistryHook

$candidates = @()
if ($env:NWA_REGISTRY_MODULE) { $candidates += $env:NWA_REGISTRY_MODULE }
$candidates += 'D:\github\nwa-network-standards\IP-Addressing-and-VLAN\NwaRegistry.psm1'
$candidates += (Join-Path $HOME 'github\nwa-network-standards\IP-Addressing-and-VLAN\NwaRegistry.psm1')

$nwaRegistryModule = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($nwaRegistryModule) {
    Import-Module $nwaRegistryModule -Force
    $global:NwaRegistryPath = $nwaRegistryModule
} else {
    Write-Warning "NwaRegistry module not found. Set NWA_REGISTRY_MODULE to the .psm1 path."
}

function Reload-NwaRegistry {
    <#
    .SYNOPSIS
        Reload NwaRegistry after editing the module.
    #>
    Remove-Module NwaRegistry -Force -ErrorAction SilentlyContinue
    Import-Module $global:NwaRegistryPath -Force
    Get-Module NwaRegistry | Select-Object Name, Path
}
Set-Alias rnwa Reload-NwaRegistry
