[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$BuildDirectory,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][ValidatePattern('^\d+\.\d+\.\d+\+\d+$')][string]$Version,
  [ValidateSet('production', 'local-test')][string]$BuildProfile = 'production',
  [string]$RuntimeDirectory,
  [switch]$Qa
)
$ErrorActionPreference = 'Stop'
$BuildProfile = $BuildProfile.ToLowerInvariant()
$source = (Resolve-Path -LiteralPath $BuildDirectory).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'OutputDirectory must be new; existing packages are preserved.' }
if ($output.StartsWith($source.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputDirectory must not be inside the build bundle.' }
$existingParent = Split-Path -Parent $output
while (-not (Test-Path -LiteralPath $existingParent -PathType Container)) {
  $existingParent = Split-Path -Parent $existingParent
  if ([string]::IsNullOrWhiteSpace($existingParent)) { throw 'Cannot resolve the output parent directory.' }
}
foreach ($path in @($source, $existingParent)) {
  $cursor = Get-Item -LiteralPath $path -Force
  while ($null -ne $cursor) {
    if ($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Build and package output paths must not contain symbolic links or junctions.' }
    $cursor = $cursor.Parent
  }
}
foreach ($required in @('flowtrace.exe', 'flutter_windows.dll', 'data\icudtl.dat', 'data\app.so')) {
  if (-not (Test-Path -LiteralPath (Join-Path $source $required) -PathType Leaf)) { throw "Missing runtime file: $required" }
}
if ((Get-Item -LiteralPath (Join-Path $source 'flowtrace.exe')).VersionInfo.FileVersion -ne $Version) { throw 'Version must match the built executable FileVersion.' }
$files = @(Get-ChildItem -LiteralPath $source -File -Recurse)
foreach ($item in @(Get-Item -LiteralPath $source -Force) + @(Get-ChildItem -LiteralPath $source -Recurse -Force)) {
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Build bundle must not contain symbolic links or junctions.' }
}
foreach ($file in $files) {
  if ($file.Name -match '(?i)\.sqlite(?:-wal|-shm)?$|\.db$|\.blob$|instance\.lock$|\.env$|qa-(?:manifest|ready|reopened|failed)') { throw 'Build bundle contains runtime business data or private QA records.' }
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'Installed Visual Studio x64 Redist is required; no system DLL search is used.' }
$visualStudio = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($visualStudio)) { throw 'Cannot locate installed Visual Studio C++ tools.' }
$redistRoot = Join-Path $visualStudio 'VC/Redist/MSVC'
if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
  $redistVersion = (Get-Content -LiteralPath (Join-Path $visualStudio 'VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt') -Raw).Trim()
  if ($redistVersion -notmatch '^\d+(?:\.\d+)+$') { throw 'Invalid installed VC Redist version.' }
  $candidates = @(Get-ChildItem -LiteralPath (Join-Path $redistRoot "$redistVersion/x64") -Directory -Filter 'Microsoft.VC*.CRT')
  if ($candidates.Count -ne 1) { throw 'Select one installed official x64 VC CRT directory explicitly with RuntimeDirectory.' }
  $RuntimeDirectory = $candidates[0].FullName
}
$runtime = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$runtimePattern = '^' + [Regex]::Escape([IO.Path]::GetFullPath($redistRoot).TrimEnd('\')) + '\\\d+(?:\.\d+)+\\x64\\Microsoft\.VC\d+\.CRT$'
if ($runtime -notmatch $runtimePattern) { throw 'RuntimeDirectory must be an installed Visual Studio official x64 Redist CRT directory.' }
$runtimeFiles = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
$runtimeVersions = @{}
foreach ($name in $runtimeFiles) {
  $file = Join-Path $runtime $name
  $bytes = [IO.File]::ReadAllBytes($file)
  if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'Invalid VC runtime DLL.' }
  $offset = [BitConverter]::ToInt32($bytes, 0x3c)
  if ($offset -lt 0 -or $offset + 6 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $offset) -ne 0x00004550 -or [BitConverter]::ToUInt16($bytes, $offset + 4) -ne 0x8664) { throw 'VC runtime DLL must be a Windows x64 PE binary.' }
  $runtimeSignature = Get-AuthenticodeSignature -LiteralPath $file
  if ($runtimeSignature.Status -ne 'Valid' -or $runtimeSignature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') { throw 'VC runtime DLL must retain a valid Microsoft signature.' }
  $runtimeVersions[$name] = (Get-Item -LiteralPath $file).VersionInfo.FileVersion
}
$null = New-Item -ItemType Directory -Path $output
$bundle = Join-Path $output 'FlowTrace'
$null = New-Item -ItemType Directory -Path $bundle
Get-ChildItem -LiteralPath $source | Where-Object { $_.Name -notin @('release-manifest.json', 'BUILD-PROFILE.txt') } | Copy-Item -Destination $bundle -Recurse
foreach ($name in $runtimeFiles) { Copy-Item -LiteralPath (Join-Path $runtime $name) -Destination (Join-Path $bundle $name) -Force }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Microsoft-VC-Runtime-NOTICE.txt') -Destination $bundle
$profileRequirement = if ($BuildProfile -eq 'local-test') {
  'Compile the executable with --dart-define=FLOWTRACE_LOCAL_TEST=true. This explicit Windows test profile allows local/LAN HTTP test servers. Public server addresses still require HTTPS.'
} else {
  'Compile the executable without FLOWTRACE_LOCAL_TEST=true. An ordinary Windows Release uses HTTPS server connections.'
}
@"
FlowTrace Windows build profile
build_profile=$BuildProfile
qa_entry=$([bool]$Qa)

$profileRequirement

BuildProfile declares the profile of the already-built executable; packaging does not inspect or change its Dart compile-time defines. The packager must match this declaration to the build command and its retained build evidence.
The QA entry flag is independent of the transport profile. Final application deliveries use the ordinary lib/main.dart entry and qa_entry=False.
User data is stored outside this package at %APPDATA%\com.flowtrace\flowtrace\flowtrace. Server addresses are configured in the application; credentials and private server configuration must not be added to the bundle.
"@ | Set-Content -LiteralPath (Join-Path $bundle 'BUILD-PROFILE.txt') -Encoding UTF8
$signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $bundle 'flowtrace.exe')
$entries = @(Get-ChildItem -LiteralPath $bundle -File -Recurse | Sort-Object FullName | ForEach-Object {
  @{path=$_.FullName.Substring($bundle.Length + 1).Replace('\','/'); bytes=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
$manifest = [ordered]@{product='FlowTrace'; version=$Version; platform='windows-x64'; build_profile=$BuildProfile; build_profile_file='BUILD-PROFILE.txt'; qa=[bool]$Qa; signature_status=[string]$signature.Status; created_utc=[DateTime]::UtcNow.ToString('o'); files=$entries; vc_runtime=@{source='installed-visual-studio-redist'; architecture='x64'; signature_status='Valid'; signer='Microsoft Corporation'; versions=$runtimeVersions; notice='Microsoft-VC-Runtime-NOTICE.txt'}; data_location='%APPDATA%\com.flowtrace\flowtrace\flowtrace'; data_in_package=$false}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $bundle 'release-manifest.json') -Encoding UTF8
$zip = Join-Path $output "FlowTrace-$Version-windows-x64.zip"
Compress-Archive -LiteralPath $bundle -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($zip))" | Set-Content -LiteralPath ("$zip.sha256") -Encoding ASCII
Write-Output ([pscustomobject]$manifest | Select-Object product,version,platform,build_profile,qa,signature_status)
Write-Output "Package: $zip"
Write-Output "SHA256: $hash"
