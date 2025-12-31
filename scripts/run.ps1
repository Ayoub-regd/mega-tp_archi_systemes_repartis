param(
  [switch]$LinuxOnly,
  [int]$WaitVagrantIdleSec = 0,
  [switch]$BestEffort,
  [switch]$PreflightOnly,
  [int[]]$ReservedPorts = @(2222, 2223, 2224),
  [switch]$SkipPortCheck,
  [switch]$FailOnPortInUse,
  [switch]$SkipVirtualBoxCheck,
  [switch]$KillVirtualBoxProcesses,
  [switch]$RestartVirtualBoxNetwork
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$projectName = Split-Path -Leaf $projectDir
$mutexName = "MegaTP_Run_$projectName"

function Show-Info {
  param([Parameter(Mandatory)] [string]$Message)
  $ts = (Get-Date).ToString('s')
  Write-Host "[$ts] [INFO] $Message"
}

function Test-IsAdministrator {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PortListeners {
  param([Parameter(Mandatory)] [int[]]$Ports)

  $results = @()
  foreach ($port in ($Ports | Where-Object { $_ -gt 0 } | Select-Object -Unique)) {
    $conns = @()
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
      $conns = @(Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Listen' })
    } else {
      $raw = & netstat -ano -p TCP 2>$null
      foreach ($line in ($raw -split "(`r`n|`n|`r)")) {
        if ($line -notmatch "LISTENING\\s+(\\d+)\\s*$") { continue }
        if ($line -match ":(?<p>\\d+)\\s+.*LISTENING\\s+(?<pid>\\d+)\\s*$") {
          if ([int]$Matches['p'] -eq $port) {
            $conns += [pscustomobject]@{
              LocalPort     = $port
              OwningProcess = [int]$Matches['pid']
              State         = 'Listen'
            }
          }
        }
      }
    }

    foreach ($c in $conns) {
      $processId = $c.OwningProcess
      $processName = $null
      try { $processName = (Get-Process -Id $processId -ErrorAction SilentlyContinue).ProcessName } catch {}
      $results += [pscustomobject]@{
        Port        = $port
        ProcessId   = $processId
        ProcessName = $processName
      }
    }
  }

  return $results
}

function Get-VBoxProcesses {
  $names = @('VBoxHeadless', 'VirtualBoxVM', 'VBoxSVC')
  $procs = @()
  foreach ($n in $names) {
    $procs += @(Get-Process -Name $n -ErrorAction SilentlyContinue)
  }
  return $procs | Sort-Object -Property Id -Unique
}

function Stop-VBoxProcesses {
  param([switch]$Force)

  $procs = Get-VBoxProcesses
  if (-not $procs -or $procs.Count -eq 0) { return }

  $ids = ($procs | Select-Object -ExpandProperty Id) -join ','
  Show-Info "Arret process VirtualBox (PID: $ids)"

  foreach ($p in $procs) {
    try { Stop-Process -Id $p.Id -ErrorAction SilentlyContinue } catch {}
  }

  Start-Sleep -Seconds 3

  if ($Force) {
    foreach ($p in $procs) {
      try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
}

function Get-VagrantProcesses {
  $procs = @()
  try {
    $query = Get-CimInstance Win32_Process -Filter "Name='vagrant.exe' OR Name='ruby.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $query) {
      $cmd = $p.CommandLine
      if (-not $cmd) { continue }
      if ($cmd -match '(?i)\bvagrant\b') {
        $procs += [pscustomobject]@{ ProcessId = $p.ProcessId; Name = $p.Name; CommandLine = $cmd }
      }
    }
  } catch {
    foreach ($p in (Get-Process vagrant, ruby -ErrorAction SilentlyContinue)) {
      $procs += [pscustomobject]@{ ProcessId = $p.Id; Name = $p.ProcessName; CommandLine = '' }
    }
  }
  return $procs
}

function Wait-VagrantIdle {
  param([int]$MaxWaitSec)

  $deadline = if ($MaxWaitSec -gt 0) { (Get-Date).AddSeconds($MaxWaitSec) } else { $null }
  while ($true) {
    $procs = Get-VagrantProcesses
    if (-not $procs -or $procs.Count -eq 0) { return }

    if (-not $deadline) {
      $ids = ($procs | Select-Object -ExpandProperty ProcessId -Unique) -join ','
      throw "Un processus Vagrant est deja en cours (PID: $ids). Relance avec -WaitVagrantIdleSec ou attends la fin."
    }

    if ((Get-Date) -ge $deadline) {
      $ids = ($procs | Select-Object -ExpandProperty ProcessId -Unique) -join ','
      throw "Timeout attente fin Vagrant (${MaxWaitSec}s). Process toujours actifs (PID): $ids"
    }

    Start-Sleep -Seconds 5
  }
}

function Invoke-VagrantStatusMachineReadable {
  $raw = & vagrant status --machine-readable 2>$null
  if ($LASTEXITCODE -ne 0) { return @{} }
  $states = @{}
  foreach ($line in ($raw -split "`r?`n")) {
    if (-not $line) { continue }
    $parts = $line.Split(',', 4)
    if ($parts.Length -lt 4) { continue }
    if ($parts[2] -ne 'state') { continue }
    $states[$parts[1]] = $parts[3]
  }
  return $states
}

function Get-VBoxRunningVmNames {
  if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) { return @() }
  try {
    $out = & VBoxManage list runningvms 2>$null
    if (-not $out) { return @() }
    $names = @()
    foreach ($line in ($out -split "(`r`n|`n|`r)")) {
      if ($line -match '^\"(?<n>.+?)\"\\s+\\{') { $names += $Matches['n'] }
    }
    return $names
  } catch {
    return @()
  }
}

function Assert-ProjectStateIsClean {
  param([string[]]$MachineNames)

  $states = Invoke-VagrantStatusMachineReadable
  if (-not $states -or $states.Count -eq 0) { return }

  $vbox = Get-VBoxRunningVmNames
  if (-not $vbox -or $vbox.Count -eq 0) { return }

  $prefix = "${projectName}_"
  $projectRunning = @($vbox | Where-Object { $_ -like "$prefix*" })
  if ($projectRunning.Count -eq 0) { return }

  $allNotCreated = $true
  foreach ($m in $MachineNames) {
    if ($states.ContainsKey($m) -and $states[$m] -ne 'not_created') { $allNotCreated = $false; break }
  }
  if (-not $allNotCreated) { return }

  $list = ($projectRunning | Select-Object -First 10) -join ', '
  throw @"
Etat sale detecte: Vagrant dit 'not_created' mais VirtualBox a des VM du projet en cours ($list).
Action: fais un nettoyage from-scratch (vagrant destroy -f + suppression .vagrant) OU supprime les VM orphelines via VBoxManage, puis relance.
"@
}

$logsDir = Join-Path $projectDir "scripts\\logs"
New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
$runId = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $logsDir "vagrant_run_$runId.log"
Start-Transcript -Path $logPath -Append | Out-Null
Show-Info "Log PowerShell: $logPath"

Push-Location $projectDir
try {
  $mutex = New-Object System.Threading.Mutex($false, $mutexName)
  $lockTaken = $false
  try {
    $lockTaken = $mutex.WaitOne(0)
    if (-not $lockTaken) {
      throw "Une execution de run.ps1 est deja en cours (mutex: $mutexName)."
    }

    Wait-VagrantIdle -MaxWaitSec $WaitVagrantIdleSec

    $env:VAGRANT_NO_PARALLEL = '1'

    if ($LinuxOnly) {
      Show-Info "Mode LinuxOnly: le provision Ansible sur admin tourne en --linux-only."
      $env:MEGATP_LINUX_ONLY = '1'
      $vms = @('node01', 'node02', 'admin')
    } else {
      Remove-Item Env:MEGATP_LINUX_ONLY -ErrorAction SilentlyContinue
      # Windows en premier: le 1er boot (sysprep) peut etre tres lent et timeouter si l'hote est deja charge.
      $vms = @('winsrv', 'node01', 'node02', 'admin')
    }

    if (-not $SkipPortCheck) {
      $listeners = Get-PortListeners -Ports $ReservedPorts
      if ($listeners.Count -gt 0) {
        $table = ($listeners | Format-Table -AutoSize | Out-String).Trim()
        $msg = @"
Ports deja utilises (LISTEN) detectes.
Ports verifies: $($ReservedPorts -join ', ')
$table
Action: ferme l'application qui ecoute, OU relance avec -SkipPortCheck si tu acceptes que Vagrant auto-corrige les forwarded ports.
"@
        if ($FailOnPortInUse) { throw $msg }
        Show-Info "WARN: $msg"
      } else {
        Show-Info "Pre-check ports OK: $($ReservedPorts -join ', ')"
      }
    }

    if (-not $SkipVirtualBoxCheck) {
      $vboxProcs = Get-VBoxProcesses
      if ($vboxProcs.Count -gt 0) {
        $ids = ($vboxProcs | Select-Object -ExpandProperty Id) -join ','
        if ($KillVirtualBoxProcesses) {
          Stop-VBoxProcesses -Force
        } else {
          Show-Info "WARN: process VirtualBox detectes (PID: $ids). Si tu as des VM orphelines, tu peux relancer avec -KillVirtualBoxProcesses."
        }
      }

      if ($RestartVirtualBoxNetwork) {
        if (-not (Test-IsAdministrator)) {
          throw "RestartVirtualBoxNetwork requiert un PowerShell lance en Administrateur."
        }
        foreach ($svcName in @('vboxnetadp', 'vboxnetlwf')) {
          $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
          if (-not $svc) { continue }
          Show-Info "Restart service: $svcName"
          try { Restart-Service -Name $svcName -Force -ErrorAction Stop } catch { Show-Info "WARN: restart $svcName a echoue: $($_.Exception.Message)" }
        }
      }
    }

    Assert-ProjectStateIsClean -MachineNames $vms

    if ($PreflightOnly) {
      Show-Info "Preflight OK (mode PreflightOnly): aucune VM n'est demarree."
      return
    }

    foreach ($vm in $vms) {
      Show-Info "vagrant up --no-parallel $vm"
      vagrant up --no-parallel $vm
      if ($LASTEXITCODE -ne 0) {
        $msg = "vagrant up ($vm) a echoue (rc=$LASTEXITCODE)"
        if ($BestEffort) { Show-Info "WARN: $msg"; continue }
        throw $msg
      }
    }
  } finally {
    if ($lockTaken) { try { $mutex.ReleaseMutex() } catch {} }
    if ($mutex) { $mutex.Dispose() }
  }
} finally {
  Remove-Item Env:MEGATP_LINUX_ONLY -ErrorAction SilentlyContinue
  Remove-Item Env:VAGRANT_NO_PARALLEL -ErrorAction SilentlyContinue
  Pop-Location
  Stop-Transcript | Out-Null
}
