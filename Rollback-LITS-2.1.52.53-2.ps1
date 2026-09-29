<#
  Rollback-LITS-2.1.52.53.ps1
  Rolls the Lenovo Intelligent Thermal Solution (LITS) driver back from 2.2.111.0
  (package n4ody12w) to 2.1.52.53 (package n4bdy62w).

  Why a plain install of n4bdy62w.exe is not enough:
    2.2.111.0 INF is dated 03/25/2026, 2.1.52.53 INF is dated 10/17/2025, same
    hardware IDs (ACPI\LEN0100 / ACPI\LEN0102). While the newer INF stays in the
    driver store, Windows keeps ranking it higher. So the newer package is removed
    from the driver store first, then 2.1.52.53 is installed.

  Usage : run elevated or as SYSTEM (Intune Win32 app / SCCM / PDQ).
          Put n4bdy62w.exe in the same folder as this script.
          https://download.lenovo.com/pccbbs/mobiles/n4bdy62w.exe
          SHA256 c30561fe7c7fda77280ad144ba656d9d40ae7422e3e446a31ba5d54fcd75d6bc
  Exit  : 0    = done, or already on 2.1.52.53 or lower
          3010 = done, reboot required
          2    = LITS device not present (not applicable)
          1    = failed (see log)
  Log   : C:\ProgramData\Lenovo\LITS_Rollback\rollback.log

  Provided as-is as an interim mitigation. Pilot on a small group first.
#>

# 0. Intune/SCCM can launch 32-bit PowerShell; pnputil.exe only exists in 64-bit System32.
if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') {
    & "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
$Target  = [version]'2.1.52.53'
$Pkg     = Join-Path $PSScriptRoot 'n4bdy62w.exe'
$WorkDir = 'C:\ProgramData\Lenovo\LITS_Rollback'
$Log     = Join-Path $WorkDir 'rollback.log'
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

function Log([string]$m) { "$(Get-Date -Format s)  $m" | Tee-Object -FilePath $Log -Append }
function Get-LitsDevice {
    Get-CimInstance Win32_PnPSignedDriver |
        Where-Object { $_.DeviceID -match '^ACPI\\LEN010[02]\\' } | Select-Object -First 1
}

try {
    # 1. Check the device and current driver version
    $dev = Get-LitsDevice
    if (-not $dev) { Log 'LITS device (ACPI\LEN0100/LEN0102) not present - not applicable.'; exit 2 }
    $cur = [version]$dev.DriverVersion
    Log "Current LITS driver: $cur ($($dev.InfName))"
    if ($cur -le $Target) { Log "Already on $cur - nothing to do."; exit 0 }

    # 2. Check the rollback package
    if (-not (Test-Path $Pkg)) { Log "Missing $Pkg"; exit 1 }
    $hash = (Get-FileHash $Pkg -Algorithm SHA256).Hash
    if ($hash -ne 'C30561FE7C7FDA77280AD144BA656D9D40AE7422E3E446A31BA5D54FCD75D6BC') {
        Log "Hash mismatch on n4bdy62w.exe ($hash) - aborting."; exit 1
    }

    # 3. Extract 2.1.52.53 (Lenovo standard extract switches)
    $ExtractDir = Join-Path $WorkDir 'n4bdy62w'
    Start-Process -FilePath $Pkg -ArgumentList "/VERYSILENT /DIR=`"$ExtractDir`" /EXTRACT=YES" -Wait
    $inf = Get-ChildItem $ExtractDir -Recurse -Filter 'LITSDrv.inf' | Select-Object -First 1
    if (-not $inf) { Log 'LITSDrv.inf not found after extraction.'; exit 1 }

    # 4. Remove every LITS driver package in the store newer than 2.1.52.53,
    #    plus the INF currently bound to the device (catches copies under another file name)
    $newer = Get-WindowsDriver -Online |
        Where-Object { ($_.OriginalFileName -match '\\litsdrv\.inf$' -or $_.Driver -eq $dev.InfName) -and
                       [version]$_.Version -gt $Target }
    foreach ($d in $newer) {
        Log "Removing $($d.Driver) (v$($d.Version)) from driver store"
        pnputil.exe /delete-driver $d.Driver /uninstall /force 2>&1 | Out-File $Log -Append
    }

    # 5. Install 2.1.52.53
    Log "Installing $($inf.FullName)"
    pnputil.exe /add-driver "$($inf.FullName)" /install 2>&1 | Out-File $Log -Append
    $rc = $LASTEXITCODE
    Log "pnputil exit code: $rc"
    if ($rc -notin 0, 3010) { exit 1 }

    # 6. Verify the result
    $after = Get-LitsDevice
    Log "LITS driver now: $($after.DriverVersion)"
    if ($after -and [version]$after.DriverVersion -gt $Target) {
        Log 'FAILED: device is still on the newer driver.'; exit 1
    }
    if (-not $after -or [version]$after.DriverVersion -ne $Target) {
        Log 'Version not yet reporting 2.1.52.53 - reboot and re-check.'
    }
    exit 3010   # reboot so LITSSVC restarts on 2.1.52.53
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    exit 1
}
