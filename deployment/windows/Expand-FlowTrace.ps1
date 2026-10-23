[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Package,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$Sha256,
  [Parameter(Mandatory=$true)][string]$InstallDirectory
)
$ErrorActionPreference = 'Stop'
$archive = (Resolve-Path -LiteralPath $Package).Path
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $Sha256) { throw 'Package SHA256 mismatch.' }
$destination = [IO.Path]::GetFullPath($InstallDirectory)
if (Test-Path -LiteralPath $destination) { throw 'InstallDirectory must be new. Keep the previous version for rollback.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in $zip.Entries) {
    $relative = $entry.FullName.Replace('/', '\')
    if ($relative -match '(^|\\)\.{1,2}(\\|$)' -or -not $seen.Add($relative)) { throw 'Duplicate or traversing path in package.' }
    $target = [IO.Path]::GetFullPath((Join-Path $destination $relative))
    if (-not $target.StartsWith($destination.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe path in package.' }
    if ($relative -notmatch '^FlowTrace[\\/]') { throw 'Unexpected package root.' }
  }
} finally { $zip.Dispose() }
Expand-Archive -LiteralPath $archive -DestinationPath $destination
$bundle = Join-Path $destination 'FlowTrace'
$manifest = Get-Content -LiteralPath (Join-Path $bundle 'release-manifest.json') -Raw | ConvertFrom-Json
if ($manifest.product -ne 'FlowTrace' -or $manifest.platform -ne 'windows-x64' -or $manifest.data_in_package -ne $false) { throw 'Invalid release manifest.' }
$expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $manifest.files) {
  if ([IO.Path]::IsPathRooted($file.path) -or $file.path -match '(^|[\\/])\.{1,2}([\\/]|$)' -or -not $expected.Add($file.path.Replace('\','/'))) { throw 'Invalid or duplicate manifest path.' }
  $target = [IO.Path]::GetFullPath((Join-Path $bundle $file.path))
  if (-not $target.StartsWith($bundle.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe manifest path.' }
  if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $file.sha256 -or (Get-Item -LiteralPath $target).Length -ne $file.bytes) { throw "Runtime file checksum mismatch: $($file.path)" }
}
$null = $expected.Add('release-manifest.json')
foreach ($file in (Get-ChildItem -LiteralPath $bundle -File -Recurse)) {
  $relative = $file.FullName.Substring($bundle.Length + 1).Replace('\','/')
  if (-not $expected.Contains($relative) -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected runtime file outside release manifest.' }
}
Write-Output "Verified new version: $($manifest.version) ($($manifest.signature_status))"
Write-Output "Executable: $(Join-Path $bundle 'flowtrace.exe')"
Write-Output 'User data and the previous installation were retained. Close the old version before starting the new executable.'
