#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath,[Parameter(Mandatory)][string]$ServiceId)
. (Join-Path $PSScriptRoot 'common.ps1')
$supervisorLease=$null
try{
  $config=Read-LocalJson $ConfigPath
  $config=Get-ServiceConfiguration $config.root
  if($config.service_id -ne $ServiceId -or $ConfigPath -ne (Join-Path $config.root 'private/service.json')){throw 'local_test_supervisor_identity_mismatch'}
  $supervisorLease=[IO.File]::Open((Join-Path $config.root 'private/supervisor.lease'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  $record=Get-ProcessRecord $PID @($ConfigPath,$ServiceId)
  $statePath=Join-Path $config.root 'private/supervisor-process.json'
  if(Test-Path -LiteralPath $statePath){
    $previous=Read-LocalJson $statePath
    foreach($item in $previous.records){
      if($item.pid -ne $PID -and (Get-Process -Id $item.pid -ErrorAction SilentlyContinue)){
        if(Test-OwnedProcess $item){throw 'local_test_supervisor_already_running'}
        throw 'local_test_supervisor_identity_unconfirmed'
      }
    }
  }
  Write-LocalJson $statePath @{service_id=$ServiceId;records=@($record)}
  $failures=0
  while(-not(Test-Path -LiteralPath (Join-Path $config.root 'private/supervisor.stop'))){
    try{
      Start-LocalDatabase $config
      foreach($mode in @('serve','worker')){
        $path=Join-Path $config.root "private/$mode-process.json"
        $running=$false
        if(Test-Path -LiteralPath $path){
          $state=Read-LocalJson $path
          if($state.service_id -ne $ServiceId){throw 'local_test_component_owner_mismatch'}
          foreach($item in $state.records){
            if(Get-Process -Id $item.pid -ErrorAction SilentlyContinue){
              if(-not(Test-OwnedProcess $item)){throw 'local_test_component_identity_unconfirmed'}
              $running=$true
            }
          }
        }
        if(-not $running){Clear-ComponentStop $config $mode;Start-AppComponent $config $mode}
      }
      $failures=0
      Write-LocalJson (Join-Path $config.root 'private/supervisor-status.json') @{service_id=$ServiceId;status='running';checked_utc=[DateTime]::UtcNow.ToString('o')}
    }catch{
      $failures++
      Write-LocalJson (Join-Path $config.root 'private/supervisor-status.json') @{service_id=$ServiceId;status='degraded';code='local_test_component_unavailable';failures=$failures;checked_utc=[DateTime]::UtcNow.ToString('o')}
      if($failures -ge 5){throw 'local_test_supervisor_repeated_failure'}
    }
    Start-Sleep -Seconds 2
  }
  Stop-AppComponent $config 'worker'
  Stop-AppComponent $config 'serve'
}catch{
  Write-Error 'local_test_supervisor_stopped: inspect this instance private status'
  exit 1
}finally{
  if($null -ne $supervisorLease){$supervisorLease.Dispose()}
}
