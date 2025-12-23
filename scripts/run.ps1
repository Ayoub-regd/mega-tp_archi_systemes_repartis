param(
  [switch]$LinuxOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir

$logsDir = Join-Path $projectDir "scripts\\logs"
New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
$runId = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $logsDir "vagrant_run_$runId.log"
Start-Transcript -Path $logPath -Append | Out-Null
Write-Host "[INFO] Log PowerShell: $logPath"

Push-Location $projectDir
try {
  if ($LinuxOnly) {
    Write-Host "[INFO] vagrant up (linux only + provision auto)"
    $env:MEGATP_LINUX_ONLY = '1'
    vagrant up node01 node02 admin
    if ($LASTEXITCODE -ne 0) { throw "vagrant up (linux) a échoué (rc=$LASTEXITCODE)" }
  } else {
    Write-Host "[INFO] vagrant up (full + provision auto)"
    Remove-Item Env:MEGATP_LINUX_ONLY -ErrorAction SilentlyContinue
    vagrant up
    if ($LASTEXITCODE -ne 0) { throw "vagrant up a échoué (rc=$LASTEXITCODE)" }
  }
} finally {
  Remove-Item Env:MEGATP_LINUX_ONLY -ErrorAction SilentlyContinue
  Pop-Location
  Stop-Transcript | Out-Null
}
