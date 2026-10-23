[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SnapshotDirectory,
  [Parameter(Mandatory=$true)][string]$DataDirectory
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $SnapshotDirectory).Path.TrimEnd('\')
$destination = [IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
if (Test-Path -LiteralPath $destination) { throw 'DataDirectory must be new; existing application data is never overwritten.' }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $destination) -PathType Container)) { throw 'DataDirectory parent must already exist.' }
foreach ($path in @($source, (Split-Path -Parent $destination))) {
  $cursor = Get-Item -LiteralPath $path -Force
  while ($null -ne $cursor) {
    if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Restore paths must not contain symbolic links or junctions.' }
    $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
  }
}
$manifest = Get-Content -LiteralPath (Join-Path $source 'snapshot-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.format -ne 'flowtrace-windows-data-v1' -or $manifest.app_stopped -ne $true -or $manifest.system_credentials_included -ne $false) { throw 'Unsupported offline snapshot manifest.' }
$expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$files = @()
foreach ($file in $manifest.files) {
  $relative = [string]$file.path
  if ([IO.Path]::IsPathRooted($relative) -or $relative -match '[\\:]|(^|/)\.{1,2}(/|$)' -or -not $expected.Add($relative)) { throw 'Invalid or duplicate snapshot path.' }
  if ($relative -notmatch '^flowtrace\.sqlite(?:-wal|-shm)?$|^attachments/[^/]+(?:/[^/]+)*$') { throw 'Unexpected file in data snapshot.' }
  $target = [IO.Path]::GetFullPath((Join-Path $source $relative))
  if (-not $target.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe snapshot path.' }
  $item = Get-Item -LiteralPath $target -Force
  $cursor = $item
  while ($null -ne $cursor -and $cursor.FullName -ne $source) {
    if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Snapshot must not contain symbolic links or junctions.' }
    $cursor = if ($cursor -is [IO.DirectoryInfo]) { $cursor.Parent } else { $cursor.Directory }
  }
  if ($item.PSIsContainer -or $item.Length -ne $file.bytes -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) { throw 'Snapshot checksum mismatch; no destination was created.' }
  $files += @{source=$item.FullName; relative=$relative; bytes=$item.Length; sha256=$file.sha256}
}
if (-not $expected.Contains('flowtrace.sqlite')) { throw 'Snapshot database is missing; no destination was created.' }
$null = New-Item -ItemType Directory -Path $destination
foreach ($file in $files) {
  $target = Join-Path $destination $file.relative
  $parent = Split-Path -Parent $target
  if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
  Copy-Item -LiteralPath $file.source -Destination $target
  if ((Get-Item -LiteralPath $target).Length -ne $file.bytes -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) { throw 'Restore copy verification failed; incomplete directory was retained.' }
}
Write-Output "Verified restored data in new directory: $destination"
Write-Output 'Start a compatible FlowTrace version with --flowtrace-data-dir pointing here. Existing data was retained; sign in again if Windows credentials are unavailable.'
