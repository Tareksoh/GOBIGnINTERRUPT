#requires -Version 5.1
<#
.SYNOPSIS
    Junction integrity check for GOBIGnINTERRUPT.

.DESCRIPTION
    Run before each WoW test session to confirm edits in the source tree
    reach the WoW AddOns load path. Catches two failure modes:

      1. The AddOns entry isn't a Junction (got replaced by a real copy —
         typically by an addon manager auto-installing a release).
      2. The Junction exists but probe-file contents differ from the source
         (shouldn't happen; cheap sanity check anyway).

    Exits 0 on success, 1 on any divergence.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\check-junction.ps1

.NOTES
    If the check fails with "NOT a junction", restore from an elevated cmd:

        rmdir /S /Q "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\GOBIGnINTERRUPT"
        mklink /J "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\GOBIGnINTERRUPT" "C:\CLAUDE\GOBIGnINTERRUPT"

    Then disable auto-update / "manage" status for GBI in CurseForge / WowUp /
    Wago so they don't replace the junction with a real copy on next launch.
#>

$ErrorActionPreference = 'Stop'

$src = 'C:\CLAUDE\GOBIGnINTERRUPT'
$dst = 'C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\GOBIGnINTERRUPT'

function Fail($msg) { Write-Host "FAIL: $msg" -ForegroundColor Red; exit 1 }
function Pass($msg) { Write-Host "OK:   $msg" -ForegroundColor Green }

if (-not (Test-Path $src)) { Fail "Source missing: $src" }
if (-not (Test-Path $dst)) { Fail "AddOns path missing: $dst" }

$item = Get-Item $dst
if ($item.LinkType -ne 'Junction') {
    Fail @"
$dst is NOT a junction.
LinkType = '$($item.LinkType)' (expected 'Junction').
The AddOns folder is now a regular directory; edits in $src will NOT reach WoW
until you re-create the link. See script header for restore commands.
"@
}
Pass "AddOns is a Junction"

# Probe the .toc since it's the file WoW reads first and changes on every release.
$probe   = 'GOBIGnINTERRUPT.toc'
$srcFile = Join-Path $src $probe
$dstFile = Join-Path $dst $probe
if (-not (Test-Path $srcFile)) { Fail "Probe file missing in source: $srcFile" }
if (-not (Test-Path $dstFile)) { Fail "Probe file missing in AddOns: $dstFile" }

$srcHash = (Get-FileHash $srcFile -Algorithm SHA256).Hash
$dstHash = (Get-FileHash $dstFile -Algorithm SHA256).Hash
if ($srcHash -ne $dstHash) {
    Fail "Junction is partially shadowed: $probe differs (src=$srcHash dst=$dstHash)"
}
Pass "$probe matches (SHA256 $($srcHash.Substring(0,12))...)"

# File count cross-check. A junction should yield identical recursive counts.
$srcCount = (Get-ChildItem $src -Recurse -File -Force | Measure-Object).Count
$dstCount = (Get-ChildItem $dst -Recurse -File -Force | Measure-Object).Count
if ($srcCount -ne $dstCount) {
    Fail "File count mismatch: src=$srcCount dst=$dstCount (junction may be partially overlaid)"
}
Pass "File count = $srcCount"

Write-Host ""
Write-Host "Junction healthy. Edits to $src reach WoW after /reload." -ForegroundColor Cyan
exit 0
