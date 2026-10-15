<#
.SYNOPSIS
    Quavance AI - Strata installer (Windows 10/11).

.DESCRIPTION
    Installs the Strata inference engine and the Qwen3.8-Flash-Next model,
    hardened by default: localhost-only, API key required, images disabled.

    This wraps Strata's own START-HERE.bat, which already detects NVIDIA and
    AMD cards. It adds a preflight check, a generated API key, a verified
    localhost bind, and an optional scheduled task so it starts at logon.

.PARAMETER Model
    Size to install. IQ2_XS (default), Q2_0, IQ3_XXS, IQ3_S, IQ1_M.

.PARAMETER Check
    Run the preflight only and change nothing.

.EXAMPLE
    .\install-strata.ps1
.EXAMPLE
    .\install-strata.ps1 -Check
.EXAMPLE
    .\install-strata.ps1 -Model IQ3_S -Context 65536 -AutoStart

.NOTES
    Run in a normal PowerShell window, not as Administrator. MIT licensed.
    Upstream: https://github.com/Niko1221/Strata
#>
[CmdletBinding()]
param(
    [string]$Dir       = "$env:USERPROFILE\Strata",
    [string]$DataDir   = "",
    [string]$Family    = "qwen",
    [string]$Model     = "IQ2_XS",
    [int]   $Context   = 0,
    [int]   $Port      = 8080,
    [switch]$AutoStart,
    [switch]$Check,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
function Info { param($m) Write-Host "   $m" }
function Ok   { param($m) Write-Host "OK " -ForegroundColor Green -NoNewline; Write-Host $m }
function Warn { param($m) Write-Host "!! " -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Step { param($m) Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }
function Die  { param($m) Write-Host "xx " -ForegroundColor Red -NoNewline; Write-Host $m; exit 1 }

# -----------------------------------------------------------------------------
# 1. Preflight
# -----------------------------------------------------------------------------
Step "Checking this PC"

$os = [Environment]::OSVersion.Version
if ($os.Major -lt 10) { Die "Windows 10 or 11 is required." }
Info "OS: Windows $($os.Major) build $($os.Build)"

$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
Info "RAM: $ramGB GB"
if ($ramGB -lt 30) { Die "Need 32 GB of RAM or more; this PC has $ramGB GB." }

$drive = (Split-Path -Qualifier $Dir)
$freeGB = [math]::Round((Get-PSDrive -Name $drive.TrimEnd(':')).Free / 1GB)
Info "Free disk on ${drive}: $freeGB GB"
if ($freeGB -lt 80) { Die "Need about 80 GB free on $drive; only $freeGB GB available." }

# GPU --------------------------------------------------------------------------
$gpuFound = $false
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $line = (& nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader | Select-Object -First 1)
    if ($line) {
        $parts = $line -split ','
        $gpuName = $parts[0].Trim()
        $gpuMem  = $parts[1].Trim()
        $drvRaw  = $parts[2].Trim()
        $drv     = $drvRaw.Split('.')[0]
        $cc      = if ($parts.Count -ge 4) { $parts[3].Trim() } else { "" }

        Info "GPU: $gpuName, $gpuMem, Driver $drvRaw"
        $gpuFound = $true

        # Pascal cards (Compute 6.x, e.g. Tesla P100/P40) max out at driver 535/550 LTS.
        if ($cc -like "6.*") {
            Info "Detected Pascal GPU (compute $cc, e.g. Tesla P100/P40)."
            Warn "Pascal uses LTS drivers (535+). Strata will build via CUDA 12.x."
            if ([int]$drv -lt 535) {
                Die "NVIDIA driver $drv is too old for Pascal; needs 535 or newer. Update driver and rerun."
            }
        } else {
            if ([int]$drv -lt 580) {
                Die "NVIDIA driver $drv is too old; Strata needs 580 or newer. Update via the NVIDIA App and rerun."
            }
        }
    }
}
if (-not $gpuFound) {
    $amd = Get-CimInstance Win32_VideoController |
           Where-Object { $_.Name -match 'Radeon|AMD' } | Select-Object -First 1
    if ($amd) {
        Info "GPU: $($amd.Name)"
        Info "AMD on Windows: setup downloads a ready-made engine, nothing is compiled."
        Info "Note that AMD on Windows cannot read images yet."
        $gpuFound = $true
    }
}
if (-not $gpuFound) {
    Die "No supported GPU found. Strata needs an NVIDIA RTX 20/30/40/50 or a supported AMD Radeon with 12 GB of VRAM or more."
}

# Page file - a real failure mode on Windows -------------------------------------
$pf = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
if (-not $pf) {
    Warn "No page file is configured. Strata can fail with 'cudaMalloc failed: out of"
    Warn "memory' even with free VRAM. Set a fixed page file (System > About > Advanced"
    Warn "system settings > Performance > Advanced > Virtual memory; Custom size, the"
    Warn "same initial and maximum, e.g. 65536 MB) and restart."
}

$minRam = switch ($Model) {
    "IQ1_M"   { 30 }
    "Q2_0"    { 46 }
    "IQ2_XS"  { 46 }
    "IQ3_XXS" { 62 }
    "IQ3_S"   { 62 }
    default   { 46 }
}
if (($ramGB + 2) -lt $minRam) {
    Warn "$Model normally wants about $minRam GB of RAM and you have $ramGB GB."
    Warn "It may run slowly by reading from the SSD, or not at all."
    if (-not $Yes) {
        if ((Read-Host "Continue anyway? [y/N]") -notmatch '^[Yy]') { exit 1 }
    }
}

Ok "preflight passed: $Family/$Model"
if ($Check) { Info "-Check given; nothing was installed."; exit 0 }

# -----------------------------------------------------------------------------
# 2. Confirm the download
# -----------------------------------------------------------------------------
if (-not $Yes) {
    Step "About to download roughly 70 GB"
    Info "On a 100 Mbit line this takes 1.5-2 hours. It resumes if interrupted."
    if ((Read-Host "Continue? [y/N]") -notmatch '^[Yy]') { exit 1 }
}

# -----------------------------------------------------------------------------
# 3. Get Strata
# -----------------------------------------------------------------------------
Step "Fetching Strata"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "git is not installed. Install it from https://git-scm.com/download/win and rerun, or download and unzip https://github.com/Niko1221/Strata/archive/refs/heads/main.zip into $Dir yourself."
}
if (Test-Path (Join-Path $Dir ".git")) {
    Info "already present, updating"
    git -C $Dir pull --quiet --ff-only
} else {
    git clone --depth=1 https://github.com/Niko1221/Strata.git $Dir
}
Set-Location $Dir
Ok "repository ready"

# -----------------------------------------------------------------------------
# 4. API key
# -----------------------------------------------------------------------------
Step "Generating an API key"
$keyFile = Join-Path $Dir ".strata-api-key"
if ((Test-Path $keyFile) -and (Get-Item $keyFile).Length -gt 0) {
    $apiKey = (Get-Content $keyFile -Raw).Trim()
    Info "reusing the existing key in $keyFile"
} else {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $apiKey = -join ($bytes | ForEach-Object { $_.ToString("x2") })
    Set-Content -Path $keyFile -Value $apiKey -NoNewline -Encoding ascii

    # Readable only by you: break inheritance, drop everyone else.
    $acl = Get-Acl $keyFile
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "$env:USERDOMAIN\$env:USERNAME", "FullControl", "Allow")
    $acl.SetAccessRule($rule)
    Set-Acl -Path $keyFile -AclObject $acl
    Ok "key written to $keyFile (readable only by you)"
}

# -----------------------------------------------------------------------------
# 5. Run Strata's own setup
# -----------------------------------------------------------------------------
Step "Running Strata setup (this is the long part)"
$setupArgs = @("--yes", "--family", $Family, "--model", $Model, "--no-start",
               "--vision", "no", "--port", "$Port",
               "--host", "127.0.0.1", "--api-key", $apiKey)
if ($Context -gt 0) { $setupArgs += @("--context", "$Context") }
if ($DataDir)       { $setupArgs += @("--data-dir", $DataDir) }

& cmd.exe /c "START-HERE.bat $($setupArgs -join ' ')"
if ($LASTEXITCODE -ne 0) { Die "Strata setup exited with code $LASTEXITCODE." }
Ok "setup finished"

# -----------------------------------------------------------------------------
# 6. Verify the hardening
#
#    setup rewrites strata-<model>.json and has been seen to change the bind
#    address and reduce the context from free RAM without saying so.
# -----------------------------------------------------------------------------
Step "Verifying the configuration"
$cfgFile = Get-ChildItem -Path $Dir -Filter "strata-*.json" | Select-Object -First 1
if (-not $cfgFile) { Die "No strata-*.json was produced; setup did not complete." }
Info "config: $($cfgFile.Name)"

$cfg = Get-Content $cfgFile.FullName -Raw | ConvertFrom-Json
$changed = @()
if ($cfg.host -ne "127.0.0.1") { $cfg.host = "127.0.0.1"; $changed += "host -> 127.0.0.1" }
if ($cfg.port -ne $Port)       { $cfg.port = $Port;       $changed += "port -> $Port" }
if (-not $cfg.api_key)         { Warn "no api_key in the config" }
$i = [array]::IndexOf($cfg.args, "--max-context")
if ($i -ge 0) { Info "context: $($cfg.args[$i + 1])" }

$argsList = [System.Collections.Generic.List[string]]::new($cfg.args)
function Set-StrataArg([string]$flag, [string]$val) {
    $idx = $argsList.IndexOf($flag)
    if ($idx -ge 0) {
        if ($idx + 1 -lt $argsList.Count) {
            $old = $argsList[$idx + 1]
            if ($old -ne $val) {
                $argsList[$idx + 1] = $val
                $script:changed += "$flag $old -> $val"
            }
        } else {
            $argsList.Add($val)
            $script:changed += "$flag -> $val"
        }
    } else {
        $argsList.Add($flag)
        $argsList.Add($val)
        $script:changed += "added $flag $val"
    }
}

# Optimized Quavence DePIN Tier 3 flags (empirically verified: 50-55 tok/s, saves 22.7% KV memory):
Set-StrataArg "--kv" "k8v4"
Set-StrataArg "--kv-resident" "32768"
Set-StrataArg "--prefill" "auto:32768"
if ($argsList.IndexOf("--spec") -lt 0) { Set-StrataArg "--spec" "4" }
if ($argsList.IndexOf("--spec-min-p") -lt 0) { Set-StrataArg "--spec-min-p" "0.5" }
if ($argsList.IndexOf("--expert-cache") -lt 0) { Set-StrataArg "--expert-cache" "auto" }
$cfg.args = $argsList.ToArray()

if ($changed.Count -gt 0) {
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $cfgFile.FullName -Encoding utf8
    Info "corrected / optimized: $($changed -join ', ')"
} else {
    Info "host, port, and high-throughput flags are as requested"
}
Ok "configuration verified"

$runBat = Get-ChildItem -Path $Dir -Filter "run-*.bat" | Select-Object -First 1
if (-not $runBat) { Die "Setup wrote no run-*.bat start script." }
Info "start script: $($runBat.Name)"

# -----------------------------------------------------------------------------
# 7. Optional: start at logon
# -----------------------------------------------------------------------------
if ($AutoStart) {
    Step "Registering a scheduled task"
    $action  = New-ScheduledTaskAction -Execute $runBat.FullName -WorkingDirectory $Dir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                   -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName "Strata" -Action $action -Trigger $trigger `
        -Settings $set -Force | Out-Null
    Ok "task 'Strata' registered; it starts at logon"
}

# -----------------------------------------------------------------------------
# 8. Start and verify
# -----------------------------------------------------------------------------
Step "Starting Strata"
Start-Process -FilePath $runBat.FullName -WorkingDirectory $Dir
Info "waiting for the model to load (up to 5 minutes on a first start)"
Info "your PC may feel slow for 1-3 minutes while it loads - that is normal"

$healthy = $false
foreach ($i in 1..60) {
    try {
        $h = Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 3
        if ($h.status -eq "ok") { $healthy = $true; break }
    } catch { }
    Start-Sleep -Seconds 5
    if ($i % 6 -eq 0) { Info "still loading ($($i * 5) s)" }
}
if ($healthy) { Ok "server is answering" } else { Warn "not answering yet - check the Strata window" }

# -----------------------------------------------------------------------------
# 9. Done
# -----------------------------------------------------------------------------
Step "Done"
Write-Host "  base URL: http://127.0.0.1:$Port/v1"
Write-Host "  API key:  $keyFile"
Write-Host @"

  Security defaults applied:
    - bound to 127.0.0.1 only, so nothing outside this PC can reach it
    - an API key is required even from this PC
    - image input is off, which removes the image-fetch code path entirely

  To use it from another device, do NOT just change the bind address. Put it on
  a private network (WireGuard, Tailscale, NetBird) and bind there, or tunnel:
      ssh -N -L 8080:127.0.0.1:8080 you@this-pc

  Start/stop:  run the start script, or close its window
  Logs:        strata-<model>.log in $Dir
  Reconfigure: START-HERE.bat --setup   (re-check the config afterwards)

"@
