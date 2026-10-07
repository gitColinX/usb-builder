# USB Builder

PowerShell tooling that builds a Windows 11 installer USB stick, with an unattended
answer file and per-model Dell drivers, without Rufus.

```powershell
.\Get-DellDriverPack.ps1 -Model <ModelCode>
.\Build-WindowsUsb.ps1 -IsoPath .\Win11.iso -AccountName alex -DriverPath .\DriverPacks\<ModelCode>\x\<ModelCode>\Win11\x64
```

The result boots on any UEFI PC, skips the Windows 11 hardware checks and the forced
Microsoft account, trims the consumer bloat, and comes up with storage, Ethernet,
Wi-Fi and graphics drivers already installed.

## Why this exists (Lesson 1)

Rufus 4.15 failed every time on one machine (Windows 11 Insider, build 26300), on every
USB stick and every setting:

```
Formatting to NTFS (using IFS)
Volume is in use
[0x00000057] The parameter is incorrect. - Retrying...
Format error: The device is in use by another process.
F:\ is mounted, but volume GUID doesn't match
```

How it was diagnosed:

1. **Process Monitor**, capturing system-wide during a failed run, showed that no
   other process held the volume. The only failures were Rufus's own volume-lock
   requests (`FSCTL`) on the new partition coming back `ACCESS DENIED`. Raw
   writes to the physical disk worked, which is why partitioning succeeded.
2. **Ruled out**: antivirus filter drivers (`fltmc` showed Malwarebytes' minifilters
   attached; the failure was the same with them fully unloaded and with Defender in
   their place), VPN, write-protect / BitLocker removable-drive policies, Windows
   Search, and Windows volume automount (`mountvol /N` changed nothing).
3. **Rufus's own log** showed the real problem: it reserves a drive letter for the main
   partition, but that letter ends up on its extra 1 MB `UEFI:NTFS` boot partition, so
   the format hits the wrong volume. This matches a long-standing Rufus issue
   ([pbatard/rufus#1640](https://github.com/pbatard/rufus/issues/1640)).

The fix was to avoid the layout that triggers it. A single **GPT + FAT32** partition
boots natively on UEFI, so no `UEFI:NTFS` helper partition is needed. The one file over
FAT32's 4 GB limit, `install.wim`, is split with `DISM /Split-Image`, which Windows
Setup reads natively.

## How it works

`Build-WindowsUsb.ps1`:

1. **Checks before erasing anything.** The target must be a USB disk and not the
   boot/system disk, Windows plus drivers must fit (if not, it lists the largest
   driver folders to exclude), and you must type the disk number to confirm.
2. Wipes the stick and creates one GPT FAT32 partition.
3. Copies the ISO with `robocopy` and splits `install.wim` into 3.8 GB `.swm` parts.
4. Renders `autounattend.xml` from the template (account name, locale).
5. Adds drivers in two tiers:
   - **`$WinPEDriver$`**: storage-controller drivers only (an Intel VMD/RST INF that
     installs a service), so Setup can see the internal SSD. See *Lesson 2* below for
     why nothing else goes here.
   - **`Drivers\`**: everything (network, chipset, graphics...), installed by `pnputil`
     from the answer file's `specialize` pass, before you reach the account screens.
6. Optionally sets the computer name during setup (`-ComputerName`).

`Get-DellDriverPack.ps1` looks the model up in Dell's signed driver-pack catalog,
downloads the newest Windows 11 pack, **verifies the MD5 against the catalog and the
Authenticode signature**, and extracts it (extract only; nothing is installed).

## Lesson 2: `0xE0000219 - 0x40031` on first boot

The first stick built this way failed immediately on the target laptop:
**"Windows could not apply unattend settings... 0xE0000219 - 0x40031"**.

- `0x40031` places the failure in the WinPE phase; `0xE0000219` is SetupAPI's
  `ERROR_NO_ASSOCIATED_SERVICE`: an INF was installed that has no driver service.
- The answer file had no driver paths, so the only INFs Setup was installing in WinPE
  were the ones in `$WinPEDriver$`. Listing them by class showed two **Extension INFs**
  (`iaStorHsa_Ext.inf`, `e2f_ext.inf`). Extension and component INFs only decorate
  another driver and add no service, so they can't be installed on their own.
- Confirmed by renaming `$WinPEDriver$` on the stick: Setup ran cleanly.

Fix: the builder now copies a driver into `$WinPEDriver$` only if its INF is a storage
controller (`Class = SCSIAdapter` or `HDC`) **and** declares `AddService`. Every other
INF is removed from that copy. Network drivers moved to `Drivers\` only; they don't
need to exist in WinPE because `pnputil` installs them during setup anyway. For a
current Dell laptop pack that leaves exactly one INF in WinPE: `iaStorVD.inf`.

## What the answer file does

| Area | Setting |
|---|---|
| Hardware checks | TPM, Secure Boot and RAM checks bypassed (`LabConfig`) |
| Account | No Microsoft account (`BypassNRO`, `HideOnlineAccountScreens`); local admin with a blank password that must be changed at first sign-in |
| Privacy | Privacy screens answered "off", telemetry at minimum policy level |
| Encryption | Automatic BitLocker device encryption off |
| Bloat | Copilot, News/Widgets, Start recommendations and suggested apps off; Teams, new Outlook and Dev Home don't auto-install; OneDrive doesn't auto-start |
| Other | Fast Startup off; drivers from `<USB>\Drivers` installed during setup |
| Optional | `-ComputerName`: computer name set during setup |

Disk selection in Setup stays manual, so the stick never wipes a drive by itself.

## Usage

```powershell
# See which driver packs Dell has for a model (model code is on the sticker)
.\Get-DellDriverPack.ps1 -Model <ModelCode> -ListOnly

# Download + verify + extract (UAC prompt for the extract)
.\Get-DellDriverPack.ps1 -Model <ModelCode>

# Build. Self-elevates; asks you to type the disk number before erasing.
.\Build-WindowsUsb.ps1 -IsoPath C:\ISOs\Win11.iso -AccountName alex `
    -DriverPath .\DriverPacks\<ModelCode>\x\<ModelCode>\Win11\x64 `
    -ExcludeDriver '<BigGpuDriver>*'   # e.g. skip a 1.9 GB GPU driver to fit a 16 GB stick
```

| Parameter | Default | Notes |
|---|---|---|
| `-IsoPath` | (required) | Windows 11 ISO |
| `-AccountName` | (required) | Local admin account to create |
| `-DiskNumber` | the only USB disk | Required if more than one USB disk is attached |
| `-Locale` | `en-US` | Input / system / UI / user locale |
| `-DriverPath` | none | Extracted driver folder, laid out as `<category>\<driver>\*.inf` |
| `-ExcludeDriver` | none | Driver folder names to skip (wildcards allowed) |
| `-WinPECategory` | `storage` | Categories scanned for `$WinPEDriver$`; only storage-controller INFs with a service are kept |
| `-ComputerName` | none | Computer name set during setup (max 15 characters) |
| `-Force` | off | Skip the typed confirmation |

Each build writes a log to `logs\`. On the installed PC, driver install output is in
`C:\Windows\Temp\usb-drivers.log`. Leave the stick plugged in until the desktop appears.

## Notes

- **Secure Boot / 2023 CA:** the ISO's bootloader may be signed with Microsoft's 2011
  CA. Current PCs trust both the 2011 and 2023 CAs. A machine that has revoked the
  2011 CA needs the 2023-signed bootloader (`Windows\Boot\EFI_EX` inside the image).
- Dell `.exe` driver packs only extract with admin (`/s /e=<folder>`). `expand.exe`
  refuses Dell's catalog `.cab`, so the script uses `tar`.
- Driver packs aren't committed: they're large and Dell's to distribute.
- Requires Windows PowerShell 5.1 or PowerShell 7.

## License

MIT
