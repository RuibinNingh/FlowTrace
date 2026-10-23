[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$DataDirectory,
  [Parameter(Mandatory=$true)][string]$SnapshotDirectory
)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath $DataDirectory).Path.TrimEnd('\')
$destination = [IO.Path]::GetFullPath($SnapshotDirectory).TrimEnd('\')
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'DataDirectory must be an existing directory.' }
if (Test-Path -LiteralPath $destination) { throw 'SnapshotDirectory must be new; existing snapshots are preserved.' }
if ($destination.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase) -or $source.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Snapshot and application data directories must be separate.' }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $destination) -PathType Container)) { throw 'Snapshot parent must already exist.' }
foreach ($path in @($source, (Split-Path -Parent $destination))) {
  $cursor = Get-Item -LiteralPath $path -Force
  while ($null -ne $cursor) {
    if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Snapshot paths must not contain symbolic links or junctions.' }
    $cursor = $cursor.Parent
  }
}
$database = Join-Path $source 'flowtrace.sqlite'
if (-not (Test-Path -LiteralPath $database -PathType Leaf)) { throw 'The application database is missing; no empty snapshot was created.' }
$lease = $null
try {
  # The runner opens the same file with a live write handle and FILE_SHARE_READ.
  # This operation refuses an active app; a leftover filename is not a lease.
  $lease = [IO.File]::Open((Join-Path $source 'flowtrace.instance.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
  $owner = [Text.Encoding]::ASCII.GetBytes("$PID`r`n")
  $lease.SetLength(0)
  $lease.Write($owner, 0, $owner.Length)
  $lease.Flush($true)
  $files = @()
  foreach ($name in @('flowtrace.sqlite', 'flowtrace.sqlite-wal', 'flowtrace.sqlite-shm')) {
    $file = Join-Path $source $name
    if (Test-Path -LiteralPath $file -PathType Leaf) { $files += Get-Item -LiteralPath $file -Force }
  }
  $attachments = Join-Path $source 'attachments'
  if (Test-Path -LiteralPath $attachments) {
    foreach ($item in @(Get-Item -LiteralPath $attachments -Force) + @(Get-ChildItem -LiteralPath $attachments -Recurse -Force)) {
      if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Attachment data must not contain symbolic links or junctions.' }
      if (-not $item.PSIsContainer) { $files += $item }
    }
  }
  foreach ($file in $files) {
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Database files must not be symbolic links.' }
  }
  $null = New-Item -ItemType Directory -Path $destination
  $entries = @()
  foreach ($file in ($files | Sort-Object FullName)) {
    $relative = $file.FullName.Substring($source.Length + 1)
    $target = Join-Path $destination $relative
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    Copy-Item -LiteralPath $file.FullName -Destination $target
    $sourceHash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $copied = Get-Item -LiteralPath $target
    if ($copied.Length -ne $file.Length -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash) { throw 'Snapshot copy verification failed; incomplete directory was retained.' }
    $entries += @{path=$relative.Replace('\','/'); bytes=$file.Length; sha256=$sourceHash}
  }
  $manifest = [ordered]@{format='flowtrace-windows-data-v1'; created_utc=[DateTime]::UtcNow.ToString('o'); source_directory=$source; app_stopped=$true; system_credentials_included=$false; files=$entries}
  $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $destination 'snapshot-manifest.json') -Encoding UTF8
  Write-Output "Verified offline data snapshot: $destination"
  Write-Output "Files: $($entries.Count); system credentials remain in Windows secure storage."
} catch {
  throw 'Offline data snapshot failed. Close FlowTrace, check directory permissions and available space; any incomplete snapshot was retained.'
} finally {
  if ($null -ne $lease) { $lease.Dispose() }
}
