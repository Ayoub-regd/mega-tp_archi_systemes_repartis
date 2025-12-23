param(
  [switch]$OpenZabbix,
  [int]$VagrantTimeoutSec = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Remove-AnsiEscapeCode {
  param([Parameter(Mandatory)] [string]$Text)
  return ($Text -replace "`e\\[[0-?]*[ -/]*[@-~]", '')
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

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()

  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()

  $timeoutMs = [Math]::Max(1, $TimeoutSec) * 1000
  if (-not $proc.WaitForExit($timeoutMs)) {
    try { $proc.Kill() } catch {}
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

function Export-TextFile {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$Content
  )

  $dir = Split-Path -Parent $Path
  New-Item -Path $dir -ItemType Directory -Force | Out-Null
  Set-Content -Path $Path -Value $Content -Encoding UTF8
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
    [Parameter(Mandatory)] [string]$User,
    [Parameter(Mandatory)] [string]$Password,
    [Parameter(Mandatory)] [string]$DashboardName
  )

  $apiUrl = "$BaseUrl/api_jsonrpc.php"
  try {
    $auth = Invoke-ZabbixApi -ApiUrl $apiUrl -Method 'user.login' -Params @{ user = $User; password = $Password } -Id 1
    $dash = Invoke-ZabbixApi -ApiUrl $apiUrl -Method 'dashboard.get' -Params @{ output = @('dashboardid','name'); filter = @{ name = @($DashboardName) } } -Auth $auth -Id 2
    if ($dash.Count -ge 1 -and $dash[0].dashboardid) {
      return "$BaseUrl/zabbix.php?action=dashboard.view&dashboardid=$($dash[0].dashboardid)"
    }
  } catch {
    # Fall back to BaseUrl if API isn't reachable.
  }

  return $BaseUrl
}

$proofDir = Join-Path $script:ProjectRoot 'docs\proofs'
New-Item -Path $proofDir -ItemType Directory -Force | Out-Null

$runId = Get-Date -Format 'yyyyMMdd_HHmmss'
Show-Info "Dossier preuves: $proofDir"
Show-Info "RunId: $runId"

Show-Info "Capture: pcs status --full"
$pcsOut = Invoke-Vagrant -Arguments 'ssh node01 -c "sudo pcs status --full"'
$pcsOut = Remove-AnsiEscapeCode -Text $pcsOut

$pcsTxt = Join-Path $proofDir "pcs_status_$runId.txt"
$pcsPng = Join-Path $proofDir "pcs_status_$runId.png"
Export-TextFile -Path $pcsTxt -Content $pcsOut
Export-TextAsPng -Path $pcsPng -Text $pcsOut -Title "node01: sudo pcs status --full ($runId)"
Copy-Item -Force $pcsPng (Join-Path $proofDir 'pcs_status.png')

Show-Info "Capture: page VIP (HTTP)"
$vipOut = Invoke-Vagrant -Arguments 'ssh admin -c "curl -fsS http://192.168.56.100/ || true"'
$vipOut = Remove-AnsiEscapeCode -Text $vipOut

$vipTxt = Join-Path $proofDir "vip_page_$runId.txt"
$vipPng = Join-Path $proofDir "vip_page_$runId.png"
Export-TextFile -Path $vipTxt -Content $vipOut
Export-TextAsPng -Path $vipPng -Text $vipOut -Title "admin: curl http://192.168.56.100/ ($runId)"
Copy-Item -Force $vipPng (Join-Path $proofDir 'vip_page.png')

Show-Info "Check: Zabbix UI (HTTP)"
$zbxOut = Invoke-Vagrant -Arguments 'ssh admin -c "curl -fsSI http://192.168.56.10/zabbix/ | head -n 5 || true"'
$zbxOut = Remove-AnsiEscapeCode -Text $zbxOut
$zbxTxt = Join-Path $proofDir "zabbix_http_$runId.txt"
$zbxPng = Join-Path $proofDir "zabbix_http_$runId.png"
Export-TextFile -Path $zbxTxt -Content $zbxOut
Export-TextAsPng -Path $zbxPng -Text $zbxOut -Title "admin: curl -I http://192.168.56.10/zabbix/ ($runId)"
Copy-Item -Force $zbxPng (Join-Path $proofDir 'zabbix_http.png')

if ($OpenZabbix) {
  $baseUrl = $env:ZABBIX_BASE_URL
  if (-not $baseUrl) { $baseUrl = 'http://192.168.56.10/zabbix' }
  $zUser = $env:ZABBIX_USER
  if (-not $zUser) { $zUser = 'Admin' }
  $zPass = $env:ZABBIX_PASSWORD
  if (-not $zPass) { $zPass = 'zabbix' }
  $dashName = $env:ZABBIX_DASHBOARD_NAME
  if (-not $dashName) { $dashName = 'MegaTP - Dashboard' }

  $dashUrl = Get-ZabbixDashboardUrl -BaseUrl $baseUrl -User $zUser -Password $zPass -DashboardName $dashName

  Show-Info "Ouverture du navigateur pour la capture du dashboard Zabbix (manuel)."
  Write-Host ""
  Write-Host "1) URL dashboard (ideal): $dashUrl"
  Write-Host "2) Login: $zUser / $zPass"
  Write-Host "3) Si besoin: menu Monitoring -> Dashboards, puis choisir '$dashName'"
  Write-Host "4) Win+Shift+S -> clique la notification -> bouton Save"
  Write-Host "5) Enregistre EXACTEMENT: docs\\proofs\\zabbix_dashboard.png"
  Write-Host ""

  Start-Process $dashUrl
  Start-Process "http://192.168.56.100/"
  Start-Process $proofDir
}

Show-Info "OK. Fichiers generes:"
Get-ChildItem -Path $proofDir -Filter "*$runId*" | Select-Object Name,Length | Format-Table -AutoSize

if (-not (Test-Path (Join-Path $proofDir 'zabbix_dashboard.png'))) {
  Show-Info "NOTE: docs\\proofs\\zabbix_dashboard.png n'existe pas (capture manuelle a faire via -OpenZabbix)."
}
