param(
  [switch]$OpenZabbix,
  [int]$VagrantTimeoutSec = 180,
  [int]$WaitVagrantIdleSec = 0,
  [switch]$EnsureUp,
  [switch]$Provision,
  [string[]]$RequiredMachines = @('node01', 'admin'),
  [switch]$BestEffort,
  [PSCredential]$ZabbixCredential,
  [string]$ZabbixUser,
  [SecureString]$ZabbixPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:ProjectName = Split-Path -Leaf $script:ProjectRoot
$script:MutexName = "MegaTP_CaptureProofs_$($script:ProjectName)"
$script:VagrantNoParallel = '1'
$script:SshExtraArgs = '-o ConnectTimeout=20 -o ConnectionAttempts=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'

function Remove-AnsiEscapeCode {
  param([Parameter(Mandatory)] [string]$Text)
  return ($Text -replace "`e\\[[0-?]*[ -/]*[@-~]", '')
}

function Stop-ProcessTree {
  param([Parameter(Mandatory)] [int]$ProcessId)

  try {
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue
    foreach ($child in ($children | Select-Object -ExpandProperty ProcessId)) {
      Stop-ProcessTree -ProcessId $child
    }
  } catch {
    # Ignore process enumeration failures.
  }

  try {
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
  } catch {
    # Ignore kill failures.
  }
}

function Invoke-Vagrant {
  param(
    [Parameter(Mandatory)] [string]$Arguments,
    [int]$TimeoutSec = $VagrantTimeoutSec
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'vagrant'
  $psi.Arguments = $Arguments
  $psi.WorkingDirectory = $script:ProjectRoot
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.Environment['VAGRANT_NO_PARALLEL'] = $script:VagrantNoParallel

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()

  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()

  $timeoutMs = [Math]::Max(1, $TimeoutSec) * 1000
  if (-not $proc.WaitForExit($timeoutMs)) {
    Stop-ProcessTree -ProcessId $proc.Id
    throw "Timeout (${TimeoutSec}s) sur: vagrant $Arguments`nAction: verifie 'vagrant status' et relance."
  }

  $stdout = $stdoutTask.GetAwaiter().GetResult()
  $stderr = $stderrTask.GetAwaiter().GetResult()

  $out = ($stdout + $stderr)
  if ($proc.ExitCode -ne 0) {
    throw "Vagrant a echoue (`"$Arguments`"):`n$out"
  }

  return $out
}

function Invoke-VagrantWithRetry {
  param(
    [Parameter(Mandatory)] [string]$Arguments,
    [int]$TimeoutSec = $VagrantTimeoutSec,
    [int]$MaxAttempts = 3,
    [int]$RetryDelaySec = 10
  )

  for ($attempt = 1; $attempt -le [Math]::Max(1, $MaxAttempts); $attempt++) {
    try {
      return Invoke-Vagrant -Arguments $Arguments -TimeoutSec $TimeoutSec
    } catch {
      if ($attempt -ge $MaxAttempts) { throw }
      Show-Info "WARN: echec vagrant (tentative $attempt/$MaxAttempts): $($_.Exception.Message)"
      Start-Sleep -Seconds $RetryDelaySec
    }
  }

  throw "Erreur interne: retry loop incoherent"
}

function Export-TextFile {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$Content
  )

  $dir = Split-Path -Parent $Path
  New-Item -Path $dir -ItemType Directory -Force | Out-Null
  Set-Content -Path $Path -Value $Content -Encoding UTF8
}

function Invoke-HttpTextBestEffort {
  param([Parameter(Mandatory)] [string]$Url)

  try {
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
    return ($resp.Content | Out-String)
  } catch {
    return "HTTP_ERROR: $($_.Exception.Message)"
  }
}

function Invoke-HttpHeadBestEffort {
  param([Parameter(Mandatory)] [string]$Url)

  try {
    $resp = Invoke-WebRequest -Method Head -Uri $Url -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
    $lines = @("HTTP $($resp.StatusCode) $($resp.StatusDescription)")
    foreach ($k in $resp.Headers.Keys) {
      $lines += ("{0}: {1}" -f $k, ($resp.Headers[$k] -join ','))
    }
    return ($lines -join "`n")
  } catch {
    return "HTTP_HEAD_ERROR: $($_.Exception.Message)"
  }
}

function Export-TextAsPng {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$Text,
    [string]$Title = ''
  )

  Add-Type -AssemblyName System.Drawing

  $clean = Remove-AnsiEscapeCode -Text $Text
  $lines = $clean -split "(`r`n|`n|`r)"

  if ($Title -ne '') {
    $lines = @($Title, ('-' * [Math]::Min(120, [Math]::Max(10, $Title.Length)))) + $lines
  }

  $font = New-Object System.Drawing.Font('Consolas', 12)
  $lineHeight = [int]([Math]::Ceiling($font.GetHeight() + 4))
  $margin = 20

  $maxWidth = 0
  $tmpBmp = New-Object System.Drawing.Bitmap(1, 1)
  $g = [System.Drawing.Graphics]::FromImage($tmpBmp)
  try {
    foreach ($line in $lines) {
      $size = $g.MeasureString($line, $font)
      $maxWidth = [Math]::Max($maxWidth, [int]([Math]::Ceiling($size.Width)))
    }
  } finally {
    $g.Dispose()
    $tmpBmp.Dispose()
  }

  $width = [Math]::Min(2000, $maxWidth + ($margin * 2))
  $height = [Math]::Min(3000, ($lines.Count * $lineHeight) + ($margin * 2))
  $bmp = New-Object System.Drawing.Bitmap($width, $height)
  $graphics = [System.Drawing.Graphics]::FromImage($bmp)
  $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

  try {
    $graphics.Clear([System.Drawing.Color]::FromArgb(16, 16, 16))
    $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 235, 235))
    try {
      $y = $margin
      foreach ($line in $lines) {
        $graphics.DrawString($line, $font, $brush, $margin, $y)
        $y += $lineHeight
        if ($y -gt ($height - $margin)) { break }
      }
    } finally {
      $brush.Dispose()
    }

    $dir = Split-Path -Parent $Path
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $graphics.Dispose()
    $bmp.Dispose()
    $font.Dispose()
  }
}

function Show-Info {
  param([Parameter(Mandatory)] [string]$Message)
  $ts = (Get-Date).ToString('s')
  Write-Host "[$ts] [INFO] $Message"
}

function Get-VagrantProcesses {
  $procs = @()
  try {
    $query = Get-CimInstance Win32_Process -Filter "Name='vagrant.exe' OR Name='ruby.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $query) {
      $cmd = $p.CommandLine
      if (-not $cmd) { continue }
      if ($cmd -match '(?i)\\bvagrant\\b') {
        $procs += [pscustomobject]@{
          ProcessId   = $p.ProcessId
          Name        = $p.Name
          CommandLine = $cmd
        }
      }
    }
  } catch {
    # Fallback: basic process names only.
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

function Get-VagrantStates {
  $status = Invoke-VagrantWithRetry -Arguments 'status --machine-readable' -TimeoutSec 120 -MaxAttempts 2 -RetryDelaySec 3
  $states = @{}
  foreach ($line in ($status -split "`r?`n")) {
    if (-not $line) { continue }
    $parts = $line.Split(',', 4)
    if ($parts.Length -lt 4) { continue }
    $target = $parts[1]
    $type = $parts[2]
    $data = $parts[3]
    if ($type -eq 'state') { $states[$target] = $data }
  }
  return $states
}

function Assert-NoOrphanProjectVms {
  param([hashtable]$VagrantStates)

  $vbox = Get-VBoxRunningVmNames
  if (-not $vbox -or $vbox.Count -eq 0) { return }

  $prefix = "$($script:ProjectName)_"
  $projectRunning = @($vbox | Where-Object { $_ -like "$prefix*" })
  if ($projectRunning.Count -eq 0) { return }

  $allNotCreated = $true
  foreach ($m in $RequiredMachines) {
    if ($VagrantStates.ContainsKey($m) -and $VagrantStates[$m] -ne 'not_created') {
      $allNotCreated = $false
      break
    }
  }
  if (-not $allNotCreated) { return }

  $list = ($projectRunning | Select-Object -First 10) -join ', '
  throw @"
Etat sale detecte: Vagrant dit 'not_created' mais VirtualBox a des VM du projet en cours ($list).
Action: fais un nettoyage from-scratch (vagrant destroy -f + suppression .vagrant) OU supprime les VM orphelines via VBoxManage, puis relance.
"@
}

function Convert-SecureStringToPlainText {
  param([Parameter(Mandatory)] [SecureString]$SecureString)
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Invoke-ZabbixApi {
  param(
    [Parameter(Mandatory)] [string]$ApiUrl,
    [Parameter(Mandatory)] [string]$Method,
    [Parameter()] $Params,
    [Parameter()] [string]$Auth,
    [Parameter()] [int]$Id = 1
  )

  if ($null -eq $Params) { $Params = @{} }
  $body = [ordered]@{
    jsonrpc = '2.0'
    method  = $Method
    params  = $Params
    id      = $Id
  }
  if ($Auth) { $body.auth = $Auth }

  $json = ($body | ConvertTo-Json -Depth 10)
  $resp = Invoke-RestMethod -Method Post -Uri $ApiUrl -ContentType 'application/json-rpc' -Body $json -TimeoutSec 10
  if ($resp.error) {
    throw "Zabbix API error: $($resp.error | ConvertTo-Json -Depth 10)"
  }
  return $resp.result
}

function Get-ZabbixDashboardUrl {
  param(
    [Parameter(Mandatory)] [string]$BaseUrl,
    [Parameter(Mandatory)] [string]$DashboardName,
    [Parameter()] [PSCredential]$Credential,
    [Parameter()] [string]$User,
    [Parameter()] [SecureString]$Password
  )

  $apiUrl = "$BaseUrl/api_jsonrpc.php"
  if ($Credential) {
    $User = $Credential.UserName
    $Password = $Credential.Password
  }
  if (-not $User -or -not $Password) {
    return $BaseUrl
  }

  try {
    $plainPassword = Convert-SecureStringToPlainText -SecureString $Password
    try {
      $auth = Invoke-ZabbixApi -ApiUrl $apiUrl -Method 'user.login' -Params @{ user = $User; password = $plainPassword } -Id 1
    } finally {
      $plainPassword = $null
    }
    $dash = Invoke-ZabbixApi -ApiUrl $apiUrl -Method 'dashboard.get' -Params @{ output = @('dashboardid','name'); filter = @{ name = @($DashboardName) } } -Auth $auth -Id 2
    if ($dash.Count -ge 1 -and $dash[0].dashboardid) {
      return "$BaseUrl/zabbix.php?action=dashboard.view&dashboardid=$($dash[0].dashboardid)"
    }
  } catch {
    # Fall back to BaseUrl if API isn't reachable.
  }

  return $BaseUrl
}

$mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
$lockTaken = $false
try {
  $lockTaken = $mutex.WaitOne(0)
  if (-not $lockTaken) {
    throw "Une execution de capture_proofs est deja en cours (mutex: $($script:MutexName))."
  }

  Wait-VagrantIdle -MaxWaitSec $WaitVagrantIdleSec

  if ($EnsureUp) {
    Show-Info "Pre-check: vagrant status"
    $states = Get-VagrantStates
    Assert-NoOrphanProjectVms -VagrantStates $states

    $toUp = @()
    foreach ($m in $RequiredMachines) {
      if (-not $states.ContainsKey($m) -or $states[$m] -ne 'running') { $toUp += $m }
    }

    if ($toUp.Count -gt 0) {
      $provArgs = if ($Provision) { '' } else { ' --no-provision' }
      foreach ($m in $toUp) {
        $upArgs = "up --no-parallel$provArgs $m"
        Show-Info "Demarrage VM (une par une): vagrant $upArgs"
        [void](Invoke-VagrantWithRetry -Arguments $upArgs -TimeoutSec ([Math]::Max($VagrantTimeoutSec, 1800)) -MaxAttempts 1)
      }
    }
  }

$proofDir = Join-Path $script:ProjectRoot 'docs\proofs'
New-Item -Path $proofDir -ItemType Directory -Force | Out-Null

$runId = Get-Date -Format 'yyyyMMdd_HHmmss'
$runDir = Join-Path $proofDir (Join-Path 'archive' $runId)
New-Item -Path $runDir -ItemType Directory -Force | Out-Null
Show-Info "Dossier preuves: $proofDir"
Show-Info "RunId: $runId"

function Invoke-CaptureStep {
  param(
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [scriptblock]$Action
  )

  try {
    & $Action
    return $true
  } catch {
    $msg = $_.Exception.Message
    Show-Info ("ERREUR: {0}: {1}" -f $Name, $msg)
    if (-not $BestEffort) { throw }
    return $false
  }
}

$hadFailure = $false

$hadFailure = $hadFailure -or (-not (Invoke-CaptureStep -Name 'pcs status --full' -Action {
  Show-Info "Capture: pcs status --full"
  $pcsOut = Invoke-VagrantWithRetry -Arguments "ssh --no-tty node01 -c ""sudo pcs status --full"" -- $($script:SshExtraArgs)" -MaxAttempts 3 -RetryDelaySec 10
  $pcsOut = Remove-AnsiEscapeCode -Text $pcsOut

  $pcsTxt = Join-Path $runDir "pcs_status_$runId.txt"
  $pcsPng = Join-Path $runDir "pcs_status_$runId.png"
  Export-TextFile -Path $pcsTxt -Content $pcsOut
  Export-TextAsPng -Path $pcsPng -Text $pcsOut -Title "node01: sudo pcs status --full ($runId)"
  Copy-Item -Force $pcsPng (Join-Path $proofDir 'pcs_status.png')
}))

$hadFailure = $hadFailure -or (-not (Invoke-CaptureStep -Name 'VIP page (HTTP)' -Action {
  Show-Info "Capture: page VIP (HTTP)"
  $vipUrl = 'http://192.168.56.100/'

  # Strategie "fiable" :
  # 1) HTTP direct depuis l'hote Windows (rapide, pas de SSH, evite les timeouts).
  # 2) Si le reseau host-only est cassé cote hote, fallback via `vagrant ssh admin` (mais avec timeout court).
  $vipOut = Invoke-HttpTextBestEffort -Url $vipUrl
  if (($vipOut -match '^HTTP_ERROR:') -or ([string]::IsNullOrWhiteSpace($vipOut))) {
    Show-Info "WARN: HTTP direct KO, fallback via vagrant ssh admin (timeout court): $vipUrl"
    $vipOut = Invoke-VagrantWithRetry -Arguments "ssh --no-tty admin -c ""curl -fsS $vipUrl || true"" -- $($script:SshExtraArgs)" -TimeoutSec 120 -MaxAttempts 1
    $vipOut = Remove-AnsiEscapeCode -Text $vipOut
  }

  $vipTxt = Join-Path $runDir "vip_page_$runId.txt"
  $vipPng = Join-Path $runDir "vip_page_$runId.png"
  Export-TextFile -Path $vipTxt -Content $vipOut
  Export-TextAsPng -Path $vipPng -Text $vipOut -Title "VIP: $vipUrl ($runId)"
  Copy-Item -Force $vipPng (Join-Path $proofDir 'vip_page.png')
}))

$hadFailure = $hadFailure -or (-not (Invoke-CaptureStep -Name 'Zabbix UI (HTTP)' -Action {
  Show-Info "Check: Zabbix UI (HTTP)"
  $zbxUrl = 'http://192.168.56.10/zabbix/'

  # Meme logique que VIP: on prefere un HEAD direct depuis l'hote, et on ne tombe sur SSH que si necessaire.
  $zbxOut = Invoke-HttpHeadBestEffort -Url $zbxUrl
  if (($zbxOut -match '^HTTP_HEAD_ERROR:') -or ([string]::IsNullOrWhiteSpace($zbxOut))) {
    Show-Info "WARN: HTTP HEAD direct KO, fallback via vagrant ssh admin (timeout court): $zbxUrl"
    $zbxOut = Invoke-VagrantWithRetry -Arguments "ssh --no-tty admin -c ""curl -fsSI $zbxUrl | head -n 5 || true"" -- $($script:SshExtraArgs)" -TimeoutSec 120 -MaxAttempts 1
    $zbxOut = Remove-AnsiEscapeCode -Text $zbxOut
  }
  $zbxTxt = Join-Path $runDir "zabbix_http_$runId.txt"
  $zbxPng = Join-Path $runDir "zabbix_http_$runId.png"
  Export-TextFile -Path $zbxTxt -Content $zbxOut
  Export-TextAsPng -Path $zbxPng -Text $zbxOut -Title "Zabbix: HEAD $zbxUrl ($runId)"
}))

if ($OpenZabbix) {
  $baseUrl = $env:ZABBIX_BASE_URL
  if (-not $baseUrl) { $baseUrl = 'http://192.168.56.10/zabbix' }
  $dashName = $env:ZABBIX_DASHBOARD_NAME
  if (-not $dashName) { $dashName = 'MegaTP - Dashboard' }

  $zUser = $ZabbixUser
  $zPassSecure = $ZabbixPassword
  $zPassPlain = $null

  if (-not $ZabbixCredential) {
    if (-not $zUser) {
      $zUser = $env:ZABBIX_USER
      if (-not $zUser) { $zUser = 'Admin' }
    }

    if (-not $zPassSecure) {
      $zPassPlain = $env:ZABBIX_PASSWORD
      if (-not $zPassPlain) { $zPassPlain = 'zabbix' }
      $zPassSecure = ConvertTo-SecureString $zPassPlain -AsPlainText -Force
    }
  }

  $dashUrl = Get-ZabbixDashboardUrl -BaseUrl $baseUrl -DashboardName $dashName -Credential $ZabbixCredential -User $zUser -Password $zPassSecure

  Show-Info "Ouverture du navigateur pour la capture du dashboard Zabbix (manuel)."
  Write-Host ""
  Write-Host "1) URL dashboard (ideal): $dashUrl"
  if ($ZabbixCredential) {
    Write-Host "2) Login: $($ZabbixCredential.UserName) / (credential)"
  } elseif ($zPassPlain) {
    Write-Host "2) Login: $zUser / $zPassPlain"
  } else {
    Write-Host "2) Login: $zUser / (voir README)"
  }
  Write-Host "3) Si besoin: menu Monitoring -> Dashboards, puis choisir '$dashName'"
  Write-Host "4) Win+Shift+S -> clique la notification -> bouton Save"
  Write-Host "5) Enregistre EXACTEMENT: docs\\proofs\\zabbix_dashboard.png"
  Write-Host ""

  Start-Process $dashUrl
  Start-Process "http://192.168.56.100/"
  Start-Process $proofDir
}

Show-Info "OK. Fichiers generes:"
Get-ChildItem -Path $runDir | Select-Object Name,Length | Format-Table -AutoSize

if (-not (Test-Path (Join-Path $proofDir 'zabbix_dashboard.png'))) {
  $alt = Join-Path $proofDir 'zabbix\\zabbix_dashboard.png'
  if (Test-Path $alt) {
    Copy-Item -Force $alt (Join-Path $proofDir 'zabbix_dashboard.png')
    Show-Info "NOTE: zabbix_dashboard.png recupere depuis docs\\proofs\\zabbix\\zabbix_dashboard.png"
  } else {
    Show-Info "NOTE: docs\\proofs\\zabbix_dashboard.png n'existe pas (capture manuelle a faire via -OpenZabbix)."
  }
}

if ($hadFailure) {
  if ($BestEffort) {
    Show-Info "NOTE: au moins une capture a echoue (mode -BestEffort)."
  } else {
    throw "Au moins une capture a echoue. Relance avec -BestEffort pour continuer malgre les erreurs, ou augmente -VagrantTimeoutSec."
  }
}
} finally {
  if ($lockTaken) { try { $mutex.ReleaseMutex() } catch {} }
  $mutex.Dispose()
}
