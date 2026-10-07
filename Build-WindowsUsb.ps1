<#
.SYNOPSIS
    Builds a Windows 11 installer USB stick without Rufus.

.DESCRIPTION
    1. Verifies the target is a removable USB disk (refuses internal/boot disks)
       and that everything will fit - all BEFORE anything is erased.
    2. Wipes it, creates one GPT FAT32 partition (boots on any UEFI PC; no extra
       UEFI:NTFS partition, so the Rufus "volume GUID doesn't match" bug can't happen).
    3. Copies the ISO and splits install.wim into <4 GB .swm pieces with DISM.
    4. Writes autounattend.xml from autounattend.template.xml (account name, locale,
       optional computer name).
    5. Optionally adds drivers:
         $WinPEDriver$  - storage controller drivers only (Setup loads these in WinPE,
                          so an Intel VMD/RST SSD is visible). Only INFs that install a
                          service are kept: an extension/component INF here makes
                          Setup fail with 0xE0000219 - 0x40031.
         Drivers\       - everything, installed by pnputil in the specialize pass
    Needs admin; asks for UAC if not elevated. Log: logs\build-<date>.log

.EXAMPLE
    .\Build-WindowsUsb.ps1 -IsoPath "$env:USERPROFILE\Downloads\Win11.iso" -AccountName alex

.EXAMPLE
    .\Build-WindowsUsb.ps1 -IsoPath C:\ISOs\Win11.iso -AccountName alex `
        -DriverPath ".\DriverPacks\<Model>\x\<Model>\Win11\x64" -ExcludeDriver '<BigGpuDriver>*'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateScript({ Test-Path $_ })] [string]$IsoPath,
    [Parameter(Mandatory)] [ValidatePattern('^[^\s"/\\\[\]:;|=,+*?<>]{1,20}$')] [string]$AccountName,
    # Disk number of the USB stick. If omitted, picks the only USB disk (fails if there are several).
    [int]$DiskNumber = -1,
    [string]$Locale = 'en-US',
    [string]$Label = 'WIN11',
    # Extracted driver folder (e.g. from Get-DellDriverPack.ps1). Layout: <category>\<driver>\*.inf
    [string]$DriverPath,
    # Driver folder names to skip (wildcards ok), e.g. '59P0Y*' to skip a big GPU driver
    [string[]]$ExcludeDriver = @(),
    # Category folders scanned for $WinPEDriver$ (only storage-controller INFs with a service are kept)
    [string[]]$WinPECategory = @('storage'),
    # Computer name to set during setup (max 15 chars)
    [ValidatePattern('^[A-Za-z0-9-]{1,15}$')] [string]$ComputerName,
    # Skip the typed confirmation (for repeat builds)
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

# --- Self-elevate --------------------------------------------------------------
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $argList += "-$k" } }
        elseif ($v -is [array]) { $argList += "-$k"; $argList += "`"$($v -join ',')`"" }
        else { $argList += "-$k"; $argList += "`"$v`"" }
    }
    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    Start-Process $shell -Verb RunAs -ArgumentList $argList
    return
}

# -File passes arrays through as one comma-joined string; split them back out
$ExcludeDriver = @($ExcludeDriver | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$WinPECategory = @($WinPECategory | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$IsoPath = (Resolve-Path $IsoPath).Path
if ($DriverPath) { $DriverPath = (Resolve-Path $DriverPath).Path }
$template = Join-Path $PSScriptRoot 'autounattend.template.xml'
$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ("build-{0:yyyy-MM-dd_HHmm}.log" -f (Get-Date))
function Test-WinPEDriverInf([string]$Path) {
    # True for a storage-controller INF that installs a service (safe and useful in WinPE)
    $text = Get-Content -LiteralPath $Path -Raw
    $class = [regex]::Match($text, '(?im)^\s*Class\s*=\s*"?([^"\r\n;]+)').Groups[1].Value.Trim()
    ($class -in 'SCSIAdapter', 'HDC') -and ($text -match '(?im)^\s*AddService\s*=')
}
function Log($m, $c = 'Gray') { $line = "$(Get-Date -f HH:mm:ss) $m"; Write-Host $line -ForegroundColor $c; Add-Content $log $line }

# --- Pick and verify the target disk ---------------------------------------------
$usbDisks = @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and -not $_.IsBoot -and -not $_.IsSystem })
if ($DiskNumber -lt 0) {
    if ($usbDisks.Count -ne 1) {
        $usbDisks | Format-Table Number, FriendlyName, @{n = 'GB'; e = { [math]::Round($_.Size / 1GB, 1) } } -AutoSize | Out-Host
        throw "Found $($usbDisks.Count) USB disks - pass -DiskNumber to choose one"
    }
    $DiskNumber = $usbDisks[0].Number
}
$disk = Get-Disk -Number $DiskNumber
if ($disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem) {
    throw "Disk $DiskNumber ($($disk.FriendlyName), $($disk.BusType)) is not a removable USB disk - refusing"
}
if ($disk.Size -gt 2TB) { throw "Disk $DiskNumber is larger than 2 TB - refusing (FAT32 target)" }
if ($disk.Size -gt 32GB) { Log "Note: disk is over 32 GB; Windows formats FAT32 only up to 32 GB, so the partition is capped at 32 GB" 'Yellow' }

# --- Size check (before wiping) -------------------------------------------------
$img = Mount-DiskImage -ImagePath $IsoPath -PassThru
try {
    $src = "$(($img | Get-Volume).DriveLetter):"
    $isoBytes = (Get-ChildItem "$src\" -Recurse -File | Measure-Object Length -Sum).Sum
} finally { Dismount-DiskImage -ImagePath $IsoPath | Out-Null }

$driverDirs = @()
$driverBytes = 0
if ($DriverPath) {
    $driverDirs = Get-ChildItem $DriverPath -Directory | ForEach-Object { Get-ChildItem $_.FullName -Directory } |
        Where-Object { $n = $_.Name; -not ($ExcludeDriver | Where-Object { $n -like $_ }) }
    $driverBytes = ($driverDirs | ForEach-Object { Get-ChildItem $_.FullName -Recurse -File } | Measure-Object Length -Sum).Sum
}
$partBytes = [math]::Min($disk.Size - 2MB, 32GB)
$needBytes = $isoBytes + $driverBytes * 1.1 + 200MB   # WinPE copy of storage/network + FAT32 slack
Log ("Target: disk {0} {1} {2:N1} GB | need ~{3:N2} GB (Windows {4:N2} + drivers {5:N2})" -f `
    $DiskNumber, $disk.FriendlyName, ($disk.Size / 1GB), ($needBytes / 1GB), ($isoBytes / 1GB), ($driverBytes / 1GB)) 'Cyan'
if ($needBytes -gt $partBytes) {
    if ($DriverPath) {
        $driverDirs | Sort-Object { (Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum } -Descending |
            Select-Object -First 5 @{n = 'Category'; e = { $_.Parent.Name } }, Name,
                @{n = 'GB'; e = { [math]::Round((Get-ChildItem $_.FullName -Recurse -File | Measure-Object Length -Sum).Sum / 1GB, 2) } } |
            Format-Table -AutoSize | Out-Host
        throw "Won't fit. Exclude some drivers with -ExcludeDriver (largest shown above) or use a bigger stick"
    }
    throw "Won't fit: need ~$([math]::Round($needBytes/1GB,1)) GB, stick has $([math]::Round($partBytes/1GB,1)) GB"
}

# --- Confirm ---------------------------------------------------------------------
if (-not $Force) {
    Write-Host ""
    Write-Host "ALL DATA ON DISK $DiskNumber ($($disk.FriendlyName), $([math]::Round($disk.Size/1GB,1)) GB) WILL BE ERASED." -ForegroundColor Red
    $answer = Read-Host "Type the disk number ($DiskNumber) to continue"
    if ($answer -ne "$DiskNumber") { Log "Cancelled by user" 'Yellow'; return }
}

try {
    # --- Partition + format ------------------------------------------------------
    Get-Process rufus* -ErrorAction SilentlyContinue | Stop-Process -Force
    Log "Wiping disk $DiskNumber and creating one GPT FAT32 partition"
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Start-Sleep 2
    if ((Get-Disk -Number $DiskNumber).PartitionStyle -eq 'RAW') { Initialize-Disk -Number $DiskNumber -PartitionStyle GPT }
    $part = if ($disk.Size -gt 32GB) { New-Partition -DiskNumber $DiskNumber -Size 32GB -AssignDriveLetter }
            else { New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter }
    Start-Sleep 2
    Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel $Label -Confirm:$false | Out-Null
    $usb = "$((Get-Partition -DiskNumber $DiskNumber -PartitionNumber $part.PartitionNumber).DriveLetter):"
    Log "Formatted FAT32 as $usb"

    # --- Windows files -------------------------------------------------------------
    $img = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $src = "$(($img | Get-Volume).DriveLetter):"
    Log "Copying Windows files from $src"
    robocopy "$src\" "$usb\" /E /XF install.wim /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
    if (Test-Path "$src\sources\install.wim") {
        Log "Splitting install.wim into 3.8 GB pieces (slow part; ~5-10 min on USB 2.0)"
        dism /Split-Image /ImageFile:"$src\sources\install.wim" /SWMFile:"$usb\sources\install.swm" /FileSize:3800 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "DISM split failed ($LASTEXITCODE)" }
    }
    Dismount-DiskImage -ImagePath $IsoPath | Out-Null

    # --- Answer file -----------------------------------------------------------------
    $xml = (Get-Content $template -Raw).Replace('{{ACCOUNT}}', $AccountName).Replace('{{LOCALE}}', $Locale).Replace('{{COMPUTERNAME}}', $ComputerName)
    # Keep or drop the optional blocks (markers removed either way)
    foreach ($block in @{ COMPUTERNAME = [bool]$ComputerName }.GetEnumerator()) {
        $pattern = "(?s)[ \t]*<!--BEGIN:$($block.Key)-->\r?\n(.*?)[ \t]*<!--END:$($block.Key)-->\r?\n"
        $xml = [regex]::Replace($xml, $pattern, $(if ($block.Value) { '$1' } else { '' }))
    }
    [xml]$xml | Out-Null   # validate
    Set-Content "$usb\autounattend.xml" $xml -Encoding utf8 -NoNewline
    Log ("Answer file written (account: {0}, locale: {1}, computer name: {2})" -f `
        $AccountName, $Locale, $(if ($ComputerName) { $ComputerName } else { 'Windows picks' }))

    # --- Drivers ---------------------------------------------------------------------
    if ($DriverPath) {
        $pe = "$usb\`$WinPEDriver`$"
        foreach ($d in $driverDirs) {
            # Setup installs every INF under $WinPEDriver$ in WinPE. An INF that adds no service
            # (Extension / SoftwareComponent) fails there with 0xE0000219 (ERROR_NO_ASSOCIATED_SERVICE)
            # and stops Setup at 0x40031, so only storage-controller INFs with a service go in.
            if ($WinPECategory -contains $d.Parent.Name) {
                $bootInfs = Get-ChildItem $d.FullName -Recurse -Filter *.inf | Where-Object { Test-WinPEDriverInf $_.FullName }
                if ($bootInfs) {
                    $dest = "$pe\$($d.Parent.Name)\$($d.Name)"
                    robocopy $d.FullName $dest /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
                    if ($LASTEXITCODE -ge 8) { throw "copy to `$WinPEDriver`$ failed ($LASTEXITCODE)" }
                    $keep = $bootInfs.FullName | ForEach-Object { $_.Replace($d.FullName, $dest) }
                    Get-ChildItem $dest -Recurse -Filter *.inf | Where-Object { $keep -notcontains $_.FullName } | Remove-Item -Force
                }
            }
            robocopy $d.FullName "$usb\Drivers\$($d.Parent.Name)\$($d.Name)" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "copy to Drivers failed ($LASTEXITCODE)" }
        }
        "Drivers from $DriverPath (excluded: $($ExcludeDriver -join ', ')). Installed by autounattend.xml during setup." |
            Set-Content "$usb\Drivers\INSTALL.TAG"
        $peCount = (Get-ChildItem -LiteralPath $pe -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
        $allCount = (Get-ChildItem "$usb\Drivers" -Recurse -Filter *.inf).Count
        Log "Drivers copied: $peCount INFs in `$WinPEDriver`$, $allCount INFs in Drivers"
    }

    $v = Get-Volume -DriveLetter $usb[0]
    Log ("SUCCESS - {0} used {1:N2} GB, {2:N2} GB free" -f $usb, (($v.Size - $v.SizeRemaining) / 1GB), ($v.SizeRemaining / 1GB)) 'Green'
    Log "On the target PC: boot from USB (Dell: F12) and leave the stick in until the desktop appears."
} catch {
    Log "FAILED: $($_.Exception.Message)" 'Red'
    Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
    throw
}
