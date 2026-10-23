#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('Install','Start','Stop','Status','Backup','RegisterLogonTask','UnregisterLogonTask')][string]$Action,
  [Parameter(Mandatory)][string]$Root,
  [string]$Version
)
. (Join-Path $PSScriptRoot 'common.ps1')

function New-LocalSecret {
  $bytes=[byte[]]::new(32)
  [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  return [Convert]::ToHexString($bytes).ToLowerInvariant()
}

function Invoke-ServiceMode($Config,[string]$Mode) {
  Invoke-LocalChild (Join-Path $Config.version_directory 'venv/Scripts/python.exe') @('-I','-m','flowtrace_server.tools.local_test_service','--config',(Join-Path $Config.root 'private/service.json'),'--service-id',$Config.service_id,'--mode',$Mode) $Config.root
}

function Start-OwnSupervisor($Config) {
  $path=Join-Path $Config.root 'private/supervisor-process.json'
  if(Test-Path -LiteralPath $path){
    $state=Read-LocalJson $path
    foreach($item in $state.records){
      if(Get-Process -Id $item.pid -ErrorAction SilentlyContinue){
        if($state.service_id -eq $Config.service_id -and (Test-OwnedProcess $item)){return}
        throw 'local_test_supervisor_start_refused'
      }
    }
  }
  Assert-PortFree $Config.http_port
  Clear-ComponentStop $Config 'supervisor'
  $pwsh=Join-Path $PSHOME 'pwsh.exe'
  $child=Start-LocalChild $pwsh @('-NoProfile','-NonInteractive','-File',(Join-Path $Config.version_directory 'management/Supervisor.ps1'),'-ConfigPath',(Join-Path $Config.root 'private/service.json'),'-ServiceId',$Config.service_id) $Config.root
  $deadline=[DateTime]::UtcNow.AddSeconds(8)
  do{
    if($child.HasExited){throw 'local_test_supervisor_exited'}
    if(Test-Path -LiteralPath $path){
      $state=Read-LocalJson $path
      if($state.service_id -eq $Config.service_id -and @($state.records|Where-Object{$_.pid -eq $child.Id -and (Test-OwnedProcess $_)}).Count -gt 0){return}
    }
    Start-Sleep -Milliseconds 100
  }while([DateTime]::UtcNow -lt $deadline)
  throw 'local_test_supervisor_registration_timeout'
}

function Stop-OwnApplication($Config) {
  Stop-AppComponent $Config 'supervisor'
  Stop-AppComponent $Config 'worker'
  Stop-AppComponent $Config 'serve'
}

try{
  $rootPath=Get-PlainPath $Root
  $owner=Get-LocalOwner $rootPath
  if($Action -eq 'Install'){
    if(-not $Version){throw 'local_test_version_required'}
    $prepared=Get-Prepared $rootPath $Version
    foreach($path in @('private','data','postgresql')){if(Test-Path -LiteralPath (Join-Path $rootPath $path)){throw 'local_test_install_requires_fresh_instance'}}
    Assert-PortFree $prepared.http_port
    Assert-PortFree $prepared.database_port
    Protect-LocalRoot $rootPath
    foreach($path in @('private','data','postgresql/data')){$null=New-Item -ItemType Directory -Path (Join-Path $rootPath $path)}
    $versionRoot=$prepared.version_directory
    Invoke-LocalChild $prepared.python @('-I','-m','venv',(Join-Path $versionRoot 'venv')) $rootPath
    $venvPython=Join-Path $versionRoot 'venv/Scripts/python.exe'
    Invoke-LocalChild $venvPython @('-I','-m','pip','--isolated','install','--no-index','--no-cache-dir','--only-binary=:all:','--find-links',(Join-Path $versionRoot 'wheelhouse'),'--require-hashes','-r',(Join-Path $versionRoot 'artifacts/requirements.lock')) $rootPath
    Invoke-LocalChild $venvPython @('-I','-m','pip','--isolated','install','--no-index','--no-cache-dir','--no-deps',$prepared.wheel) $rootPath
    $short=$owner.service_id.Replace('-','').Substring(0,16)
    $pg=@{administrator="flowtrace_admin_$short";admin_password=(New-LocalSecret);role="flowtrace_service_$short";role_password=(New-LocalSecret);database="flowtrace_local_$short"}
    $bin=Join-Path $versionRoot 'postgresql/bin'
    $config=@{format='flowtrace-local-test-service-v1';service_id=$owner.service_id;root=$rootPath;version=$Version;version_directory=$versionRoot;web_release_id=$prepared.web_release_id;host='127.0.0.1';http_port=$prepared.http_port;database_port=$prepared.database_port;postgresql=$pg;initial_admin=@{username='flowtrace_owner';password=(New-LocalSecret)};settings=@{environment='test';database_url="postgresql+psycopg://$($pg.role):$($pg.role_password)@127.0.0.1:$($prepared.database_port)/$($pg.database)";data_directory=(Join-Path $rootPath 'data');allowed_hosts=@('localhost','127.0.0.1');cors_origins=@();pg_dump_executable=(Join-Path $bin 'pg_dump.exe')}}
    Write-LocalJson (Join-Path $rootPath 'private/service.json') $config
    $passwordFile=Get-PlainPath (Join-Path $rootPath 'private/initdb-password.txt')
    [IO.File]::WriteAllText($passwordFile,$pg.admin_password,[Text.UTF8Encoding]::new($false))
    try{
      Invoke-LocalChild (Join-Path $bin 'initdb.exe') @('-D',(Join-Path $rootPath 'postgresql/data'),'--username',$pg.administrator,'--pwfile',$passwordFile,'--auth-local=scram-sha-256','--auth-host=scram-sha-256','--encoding=UTF8') $rootPath
    }finally{if(Test-Path -LiteralPath $passwordFile){Remove-Item -LiteralPath $passwordFile}}
    Initialize-PostgresLogging $config
    Start-LocalDatabase $config
    try{Invoke-ServiceMode $config 'provision'}finally{Stop-LocalDatabase $config}
    Write-LocalJson (Join-Path $rootPath 'installed.json') @{format='flowtrace-local-test-installed-v1';service_id=$owner.service_id;version=$Version;installed_utc=[DateTime]::UtcNow.ToString('o');task_registered=$false}
    @{status='installed-stopped';service_id=$owner.service_id;version=$Version;task_registered=$false}|ConvertTo-Json
    exit 0
  }
  if(-not(Test-Path -LiteralPath (Join-Path $rootPath 'installed.json'))){
    if($Action -eq 'Status'){
      if(Test-Path -LiteralPath (Join-Path $rootPath 'private/service.json')){@{status='installation-incomplete';service_id=$owner.service_id;inspect_owned_process_state=$true}|ConvertTo-Json}
      else{@{status='prepared-not-installed';service_id=$owner.service_id;started=$false;task_registered=$false}|ConvertTo-Json}
      exit 0
    }
    throw 'local_test_not_installed'
  }
  $config=Get-ServiceConfiguration $rootPath
  switch($Action){
    'Start'{Start-OwnSupervisor $config;@{status='start-requested';service_id=$config.service_id}|ConvertTo-Json}
    'Stop'{Stop-OwnApplication $config;Stop-LocalDatabase $config;@{status='stopped';service_id=$config.service_id}|ConvertTo-Json}
    'Status'{
      $states=@{}
      foreach($mode in @('supervisor','serve','worker')){
        $path=Join-Path $rootPath "private/$mode-process.json"
        $state=if(Test-Path -LiteralPath $path){Read-LocalJson $path}else{$null}
        $states[$mode]=if($state -and $state.service_id -eq $config.service_id){@($state.records | Where-Object {Test-OwnedProcess $_}).Count -gt 0}else{$false}
      }
      $identityPath=Join-Path $rootPath 'private/server-identity.json'
      $ready=$false
      if($states.serve -and (Test-Path -LiteralPath $identityPath)){
        try{
          $health=Invoke-WebRequest -Uri "http://127.0.0.1:$($config.http_port)/health/ready" -TimeoutSec 3 -NoProxy
          $info=Invoke-RestMethod -Uri "http://127.0.0.1:$($config.http_port)/api/v1/server-info" -TimeoutSec 3 -NoProxy
          $expected=Read-LocalJson $identityPath
          $ready=$health.StatusCode -eq 200 -and $info.instance_id -eq $expected.instance_id -and $info.sync_epoch -eq $expected.sync_epoch
        }catch{$ready=$false}
      }
      @{service_id=$config.service_id;version=$config.version;processes=$states;ready=$ready;url="http://127.0.0.1:$($config.http_port)/"}|ConvertTo-Json -Depth 5
    }
    'Backup'{
      $wasRunning=$false
      $databaseWasRunning=$false
      $databaseStarted=$false
      $path=Join-Path $rootPath 'private/supervisor-process.json'
      if(Test-Path -LiteralPath $path){$state=Read-LocalJson $path;$wasRunning=@($state.records|Where-Object{Test-OwnedProcess $_}).Count -gt 0}
      $databaseState=Join-Path $rootPath 'private/database-process.json'
      if(Test-Path -LiteralPath $databaseState){$pgState=Read-LocalJson $databaseState;$databaseWasRunning=$pgState.service_id -eq $config.service_id -and (Test-OwnedProcess $pgState.record)}
      try{Stop-OwnApplication $config;Start-LocalDatabase $config;$databaseStarted=$true;Invoke-ServiceMode $config 'backup'}finally{if($wasRunning){Start-OwnSupervisor $config}elseif($databaseStarted -and -not $databaseWasRunning){Stop-LocalDatabase $config}}
    }
    'RegisterLogonTask'{
      $name='FlowTrace-LocalTest-'+$config.service_id
      if(Get-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction SilentlyContinue){throw 'local_test_task_already_exists'}
      $arguments=Get-LogonTaskArguments $config
      $taskAction=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'pwsh.exe') -Argument $arguments -WorkingDirectory $rootPath
      $trigger=New-ScheduledTaskTrigger -AtLogOn -User $owner.user_sid
      $principal=New-ScheduledTaskPrincipal -UserId $owner.user_sid -LogonType Interactive -RunLevel Limited
      $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
      $null=Register-ScheduledTask -TaskPath '\' -TaskName $name -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings
      @{status='logon-task-registered';task=$name;run_level='limited';password_stored=$false}|ConvertTo-Json
    }
    'UnregisterLogonTask'{
      $name='FlowTrace-LocalTest-'+$config.service_id
      $task=Get-ScheduledTask -TaskPath '\' -TaskName $name -ErrorAction Stop
      if(-not(Test-OwnedLogonTask $task $config $owner.user_sid)){throw 'local_test_task_remove_refused'}
      Unregister-ScheduledTask -TaskPath '\' -TaskName $name -Confirm:$false
      @{status='logon-task-unregistered';task=$name}|ConvertTo-Json
    }
  }
}catch{
  Write-Error 'local_test_action_failed: existing version and data retained; inspect private state'
  exit 1
}
