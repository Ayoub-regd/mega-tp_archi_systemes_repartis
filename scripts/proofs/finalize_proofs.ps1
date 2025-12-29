param(
  [switch]$Archive,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$proofDir = Join-Path $projectRoot 'docs\proofs'
$archiveDir = Join-Path $proofDir '_archive_local'

function Info {
  param([Parameter(Mandatory)] [string]$Message)
  $ts = (Get-Date).ToString('s')
  Write-Host "[$ts] [INFO] $Message"
}

function Ensure-Dir {
  param([Parameter(Mandatory)] [string]$Path)
  if ($DryRun) { return }
  New-Item -Path $Path -ItemType Directory -Force | Out-Null
}

function Get-NewestFile {
  param(
    [Parameter(Mandatory)] [string]$Dir,
    [Parameter(Mandatory)] [string]$Filter
  )
  if (-not (Test-Path $Dir)) { return $null }
  return Get-ChildItem -Path $Dir -File -Filter $Filter -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

function Get-NewestFileRecursive {
  param(
    [Parameter(Mandatory)] [string]$Dir,
    [Parameter(Mandatory)] [string]$Filter
  )
  if (-not (Test-Path $Dir)) { return $null }
  return Get-ChildItem -Path $Dir -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

function Select-Newest {
  param([Parameter(Mandatory)] $Candidates)
  return @($Candidates) |
    Where-Object { $_ } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

function Copy-IfNewer {
  param(
    [Parameter(Mandatory)] [string]$SourcePath,
    [Parameter(Mandatory)] [string]$DestPath
  )

  if (-not (Test-Path $SourcePath)) { return $false }

  $src = Get-Item $SourcePath
  $dst = if (Test-Path $DestPath) { Get-Item $DestPath } else { $null }

  $shouldCopy = ($null -eq $dst) -or ($src.LastWriteTime -gt $dst.LastWriteTime)
  if (-not $shouldCopy) { return $false }

  Info "MAJ: $([IO.Path]::GetFileName($DestPath)) <= $([IO.Path]::GetFileName($SourcePath))"
  if (-not $DryRun) {
    Copy-Item -Force $SourcePath $DestPath
  }
  return $true
}

Info "Dossier preuves: $proofDir"
if (-not (Test-Path $proofDir)) {
  Ensure-Dir $proofDir
}

# 1) Normaliser les 3 preuves attendues par README (noms stables)

$archiveRoot = Join-Path $proofDir 'archive'

$pcsNewest = Select-Newest @(
  (Get-NewestFile -Dir $proofDir -Filter 'pcs_status_*.png')
  (Get-NewestFileRecursive -Dir $archiveRoot -Filter 'pcs_status_*.png')
)
if ($pcsNewest) { [void](Copy-IfNewer -SourcePath $pcsNewest.FullName -DestPath (Join-Path $proofDir 'pcs_status.png')) }

$vipNewest = Select-Newest @(
  (Get-NewestFile -Dir $proofDir -Filter 'vip_page_*.png')
  (Get-NewestFileRecursive -Dir $archiveRoot -Filter 'vip_page_*.png')
)
if ($vipNewest) { [void](Copy-IfNewer -SourcePath $vipNewest.FullName -DestPath (Join-Path $proofDir 'vip_page.png')) }

# Zabbix dashboard: soit dans docs\proofs\, soit dans docs\proofs\zabbix\
$zDashRoot = Join-Path $proofDir 'zabbix_dashboard.png'
$zDashAlt = Join-Path $proofDir 'zabbix\zabbix_dashboard.png'
if (Test-Path $zDashAlt) { [void](Copy-IfNewer -SourcePath $zDashAlt -DestPath $zDashRoot) }

# 2) Optionnel: ranger les doublons dans un dossier d'archive local
if ($Archive) {
  $runId = Get-Date -Format 'yyyyMMdd_HHmmss'
  $dest = Join-Path $archiveDir $runId
  Info "Archive locale: $dest"
  Ensure-Dir $dest

  $patterns = @(
    '*_20*.png',
    '*_20*.txt'
  )

  foreach ($p in $patterns) {
    foreach ($f in (Get-ChildItem -Path $proofDir -File -Filter $p -ErrorAction SilentlyContinue)) {
      $target = Join-Path $dest $f.Name
      Info "ARCHIVE: $($f.Name) -> _archive_local\\$runId\\$($f.Name)"
      if (-not $DryRun) {
        Move-Item -Force $f.FullName $target
      }
    }
  }

  $zDir = Join-Path $proofDir 'zabbix'
  if (Test-Path $zDir) {
    $zDest = Join-Path $dest 'zabbix'
    Ensure-Dir $zDest
    foreach ($f in (Get-ChildItem -Path $zDir -File -ErrorAction SilentlyContinue)) {
      $target = Join-Path $zDest $f.Name
      Info "ARCHIVE: zabbix\\$($f.Name) -> _archive_local\\$runId\\zabbix\\$($f.Name)"
      if (-not $DryRun) {
        Move-Item -Force $f.FullName $target
      }
    }
  }
}

Info "Etat final attendu (README):"
Get-ChildItem -Path $proofDir -File -Filter '*.png' |
  Where-Object { $_.Name -in @('pcs_status.png','vip_page.png','zabbix_dashboard.png') } |
  Select-Object Name,LastWriteTime,Length |
  Format-Table -AutoSize
