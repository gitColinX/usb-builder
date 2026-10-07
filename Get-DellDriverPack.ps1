<#
.SYNOPSIS
    Downloads and extracts the official Dell Windows 11 driver pack for a model.

.DESCRIPTION
    Looks the model up in Dell's signed driver pack catalog (downloads.dell.com),
    downloads the newest Windows 11 x64 pack, verifies its MD5 against the catalog
    and its Authenticode signature, then extracts it (extract only, nothing is
    installed). Extraction needs admin; the script asks for UAC if needed.

.EXAMPLE
    .\Get-DellDriverPack.ps1 -Model <ModelCode>
    # -> DriverPacks\<ModelCode>\x\<ModelCode>\Win11\x64\...
#>
[CmdletBinding()]
param(
    # Dell model code or name as printed on the sticker, e.g. the code on the bottom sticker, or the model name
    [Parameter(Mandatory)] [string]$Model,
    [string]$OutRoot = (Join-Path $PSScriptRoot 'DriverPacks'),
    # Show matching packs without downloading
    [switch]$ListOnly
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$catDir = Join-Path $OutRoot '_catalog'
New-Item -ItemType Directory -Force $catDir | Out-Null
$cab = Join-Path $catDir 'DriverPackCatalog.cab'
Write-Host "Downloading Dell driver pack catalog..."
Invoke-WebRequest 'https://downloads.dell.com/catalog/DriverPackCatalog.cab' -OutFile $cab -UseBasicParsing
if ((Get-AuthenticodeSignature $cab).Status -ne 'Valid') { throw "Catalog signature is not valid" }
# expand.exe refuses this cab ("cannot expand onto itself"); bsdtar handles it.
tar -xf $cab -C $catDir
[xml]$cat = Get-Content (Join-Path $catDir 'DriverPackCatalog.xml')

$packs = $cat.DriverPackManifest.DriverPackage | Where-Object {
    $models = ($_.SupportedSystems.Brand.Model | ForEach-Object { "$($_.name) $($_.systemID)" }) -join ' '
    $os     = ($_.SupportedOperatingSystems.OperatingSystem | ForEach-Object { $_.osCode }) -join ' '
    $models -match [regex]::Escape($Model) -and $os -match 'Windows11'
} | Sort-Object { [datetime]$_.dateTime } -Descending

if (-not $packs) { throw "No Windows 11 driver pack found for '$Model' in Dell's catalog" }
$packs | ForEach-Object {
    [pscustomobject]@{
        Models  = ($_.SupportedSystems.Brand.Model | ForEach-Object { $_.name } | Sort-Object -Unique) -join '; '
        Version = $_.dellVersion
        Date    = ([datetime]$_.dateTime).ToString('yyyy-MM-dd')
        SizeGB  = [math]::Round([int64]$_.size / 1GB, 2)
        File    = Split-Path $_.path -Leaf
    }
} | Format-Table -AutoSize | Out-Host
if ($ListOnly) { return }

$p = $packs[0]
$name = Split-Path $p.path -Leaf
$modelDir = Join-Path $OutRoot ($Model -replace '[^\w\-]', '_')
New-Item -ItemType Directory -Force $modelDir | Out-Null
$exe = Join-Path $modelDir $name

if ((Test-Path $exe) -and (Get-FileHash $exe -Algorithm MD5).Hash -eq $p.hashMD5) {
    Write-Host "Already downloaded and verified: $name"
} else {
    Write-Host ("Downloading {0} ({1:N2} GB)..." -f $name, ([int64]$p.size / 1GB))
    Start-BitsTransfer -Source "https://$($cat.DriverPackManifest.baseLocation)/$($p.path)" -Destination $exe
    if ((Get-FileHash $exe -Algorithm MD5).Hash -ne $p.hashMD5) { throw "MD5 mismatch - download corrupted" }
}
$sig = Get-AuthenticodeSignature $exe
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Dell') { throw "Driver pack is not validly signed by Dell" }
Write-Host "Verified: MD5 matches catalog, signed by $($sig.SignerCertificate.Subject)"

$x = Join-Path $modelDir 'x'
Write-Host "Extracting (UAC prompt)..."
# The Dell self-extractor needs admin; /s /e= extracts only.
Start-Process $exe -ArgumentList '/s', "/e=$x" -Verb RunAs -Wait
$infs = Get-ChildItem $x -Recurse -Filter *.inf
if (-not $infs) { throw "Extraction produced no drivers" }
# Dell packs extract as <model>\Win11\x64\<category>\<driver>
$root = (Get-ChildItem $x -Recurse -Directory -Filter x64 | Select-Object -First 1).FullName
if (-not $root) { $root = $x }
Write-Host ("Done: {0} drivers in {1}" -f $infs.Count, $root)
Write-Host "Use it with:  .\Build-WindowsUsb.ps1 -DriverPath `"$root`" ..."
