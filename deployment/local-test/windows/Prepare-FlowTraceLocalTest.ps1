#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Root,
  [Parameter(Mandatory)][string]$Version,
  [Parameter(Mandatory)][string]$Python,
  [Parameter(Mandatory)][string]$PythonSha256,
  [Parameter(Mandatory)][string]$ServerWheel,
  [Parameter(Mandatory)][string]$ServerWheelSha256,
  [Parameter(Mandatory)][string]$RequirementsLock,
  [Parameter(Mandatory)][string]$RequirementsLockSha256,
  [Parameter(Mandatory)][string]$WheelhouseZip,
  [Parameter(Mandatory)][string]$WheelhouseSha256,
  [Parameter(Mandatory)][string]$WebZip,
  [Parameter(Mandatory)][string]$WebSha256,
  [Parameter(Mandatory)][string]$PostgresDistribution,
  [Parameter(Mandatory)][string]$PostgresManifest,
  [Parameter(Mandatory)][string]$PostgresManifestSha256,
  [Parameter(Mandatory)][int]$HttpPort,
  [Parameter(Mandatory)][int]$DatabasePort
)
. (Join-Path $PSScriptRoot 'common.ps1')
try {
  $pythonPath=Get-PlainPath $Python
  if($PythonSha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $pythonPath -Algorithm SHA256).Hash -ne $PythonSha256){throw 'local_test_python_hash_mismatch'}
  Assert-PortFree $HttpPort
  Assert-PortFree $DatabasePort
  $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $arguments=@('-I',(Join-Path $PSScriptRoot 'artifact_guard.py'),'--root',$Root,'--version',$Version,'--user-sid',$sid,'--python',$pythonPath,'--python-sha256',$PythonSha256,'--wheel',$ServerWheel,'--wheel-sha256',$ServerWheelSha256,'--lock',$RequirementsLock,'--lock-sha256',$RequirementsLockSha256,'--wheelhouse',$WheelhouseZip,'--wheelhouse-sha256',$WheelhouseSha256,'--web',$WebZip,'--web-sha256',$WebSha256,'--postgres',$PostgresDistribution,'--postgres-manifest',$PostgresManifest,'--postgres-manifest-sha256',$PostgresManifestSha256,'--http-port',"$HttpPort",'--database-port',"$DatabasePort")
  $result=& $pythonPath @arguments
  if($LASTEXITCODE -ne 0){throw 'local_test_preparation_failed'}
  Protect-LocalRoot $Root
  Write-Output $result
}catch{
  Write-Error 'local_test_preparation_failed: no installation, service startup or task registration performed'
  exit 1
}
