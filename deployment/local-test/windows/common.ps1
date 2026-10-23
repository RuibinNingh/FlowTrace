#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PlainPath([string]$Path) {
  $absolute = [IO.Path]::GetFullPath($Path)
  $cursor = $absolute
  while (-not (Test-Path -LiteralPath $cursor)) {
    $cursor = Split-Path -Parent $cursor
    if (-not $cursor) { throw 'local_test_path_invalid' }
  }
  $item = Get-Item -LiteralPath $cursor -Force
  while ($null -ne $item) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'local_test_linked_path' }
    $item = if ($item -is [IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
  }
  return $absolute
}

function Read-LocalJson([string]$Path) {
  $checked = Get-PlainPath $Path
  if ((Get-Item -LiteralPath $checked).Length -gt 16MB) { throw 'local_test_json_too_large' }
  return Get-Content -LiteralPath $checked -Raw | ConvertFrom-Json -AsHashtable
}

function Write-LocalJson([string]$Path, $Value) {
  $checked = Get-PlainPath $Path
  $temporary = "$checked.$([Guid]::NewGuid().ToString('N')).tmp"
  [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
  [IO.File]::Move($temporary, $checked, $true)
}

function Get-LocalOwner([string]$Root) {
  $rootPath = Get-PlainPath $Root
  $owner = Read-LocalJson (Join-Path $rootPath 'service-owner.json')
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if ($owner.format -ne 'flowtrace-local-test-owner-v1' -or $owner.user_sid -ne $sid) { throw 'local_test_owner_mismatch' }
  $null = [Guid]::Parse($owner.service_id)
  return $owner
}

function Protect-LocalRoot([string]$Root) {
  $owner = Get-LocalOwner $Root
  $null = & icacls.exe (Get-PlainPath $Root) '/inheritance:r' '/grant:r' "*$($owner.user_sid):(OI)(CI)F" 2>&1
  if ($LASTEXITCODE -ne 0) { throw 'local_test_acl_failed' }
}

function Get-Prepared([string]$Root, [string]$Version) {
  $owner = Get-LocalOwner $Root
  if ($Version -notmatch '^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$' -or $Version.Contains('..')) { throw 'local_test_version_invalid' }
  $directory = Join-Path (Get-PlainPath $Root) "versions/$Version"
  $prepared = Read-LocalJson (Join-Path $directory 'prepared.json')
  if ($prepared.format -ne 'flowtrace-local-test-prepared-v1' -or $prepared.service_id -ne $owner.service_id -or $prepared.version_directory -ne $directory) { throw 'local_test_prepared_mismatch' }
  foreach ($file in $prepared.files) {
    if ($file.path -match '(^|/|\\)\.\.(/|\\|$)|:|^[/\\]') { throw 'local_test_manifest_path_invalid' }
    $path = Get-PlainPath (Join-Path $directory $file.path)
    if ((Get-Item -LiteralPath $path).Length -ne $file.bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) { throw 'local_test_staged_hash_mismatch' }
  }
  foreach ($pair in @(@($prepared.python,$prepared.python_sha256), @($prepared.python_base,$prepared.python_base_sha256))) {
    if ((Get-FileHash -LiteralPath (Get-PlainPath $pair[0]) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pair[1]) { throw 'local_test_python_changed' }
  }
  return $prepared
}

function Get-ServiceConfiguration([string]$Root) {
  $owner = Get-LocalOwner $Root
  $path = Join-Path (Get-PlainPath $Root) 'private/service.json'
  $config = Read-LocalJson $path
  if ($config.format -ne 'flowtrace-local-test-service-v1' -or $config.service_id -ne $owner.service_id -or $config.root -ne (Get-PlainPath $Root)) { throw 'local_test_configuration_mismatch' }
  $prepared = Get-Prepared $Root $config.version
  if($config.version_directory -ne $prepared.version_directory -or $config.http_port -ne $prepared.http_port -or $config.database_port -ne $prepared.database_port -or $config.host -ne '127.0.0.1'){throw 'local_test_configuration_boundary'}
  return $config
}

function Assert-PortFree([int]$Port) {
  if ($Port -lt 1024 -or $Port -gt 65535 -or $Port -in @(18080,55432)) { throw 'local_test_port_invalid' }
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
  try { $listener.Start() } catch { throw 'local_test_port_in_use' } finally { $listener.Stop() }
}

if (-not ('FlowTraceLocalPinnedProcess' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.IO;
using Microsoft.Win32.SafeHandles;
public static class FlowTraceLocalLogFile {
  [StructLayout(LayoutKind.Sequential)] struct FileInformation {
    public uint Attributes;
    public System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write;
    public uint VolumeSerial,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
  }
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(IntPtr h,out FileInformation info);
  [DllImport("kernel32.dll")] static extern uint GetFileType(IntPtr h);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
  public static void Reset(string path) {
    using(var file=CreateFileW(path,0xC0000000,0,IntPtr.Zero,4,0x200080,IntPtr.Zero)) {
      if(file.IsInvalid) throw new IOException("local_test_log_file_unavailable");
      var handle=file.DangerousGetHandle(); FileInformation info;
      if(!GetFileInformationByHandle(handle,out info) || GetFileType(handle)!=1 || info.Links!=1 || (info.Attributes & (1024|16))!=0)
        throw new IOException("local_test_log_file_refused");
      using(var stream=new FileStream(file,FileAccess.ReadWrite)) { stream.SetLength(0); }
    }
  }
}
public sealed class FlowTraceLocalPinnedProcess : IDisposable {
  IntPtr handle;
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr h, out long create, out long exit, out long kernel, out long user);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder path, ref int size);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint timeout);
  [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint exitCode);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  public FlowTraceLocalPinnedProcess(int pid) { handle=OpenProcess(0x1000|0x100000|1,false,pid); }
  public bool Matches(long ticks,string executable) {
    if(handle==IntPtr.Zero || WaitForSingleObject(handle,0)!=258) return false;
    long c,e,k,u; if(!GetProcessTimes(handle,out c,out e,out k,out u)) return false;
    var text=new StringBuilder(32768); int size=text.Capacity;
    return DateTime.FromFileTimeUtc(c).Ticks==ticks && QueryFullProcessImageName(handle,0,text,ref size)
      && string.Equals(text.ToString(),executable,StringComparison.OrdinalIgnoreCase);
  }
  public bool Terminate() { return handle!=IntPtr.Zero && TerminateProcess(handle,0); }
  public void Dispose() { if(handle!=IntPtr.Zero) { CloseHandle(handle); handle=IntPtr.Zero; } }
}
'@
}

function Get-ProcessRecord([int]$Id, [string[]]$Markers) {
  $process = Get-Process -Id $Id -ErrorAction Stop
  try{$record = @{pid=$Id;start_ticks=$process.StartTime.ToUniversalTime().Ticks;exe=$process.Path;markers=$Markers}}finally{$process.Dispose()}
  if (-not (Test-OwnedProcess $record)) { throw 'local_test_process_identity_unavailable' }
  return $record
}

function Test-OwnedProcess($Record, [switch]$Terminate) {
  $pinned = [FlowTraceLocalPinnedProcess]::new([int]$Record.pid)
  try {
    if (-not $pinned.Matches([long]$Record.start_ticks,[string]$Record.exe)) { return $false }
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $([int]$Record.pid)" -ErrorAction Stop
    foreach ($marker in $Record.markers) {
      if (-not $marker -or -not $cim.CommandLine -or $cim.CommandLine.IndexOf($marker,[StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    if ($Terminate) { return $pinned.Terminate() }
    return $true
  } finally { $pinned.Dispose() }
}

function Start-LocalChild([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = Get-PlainPath $Executable
  $start.WorkingDirectory = Get-PlainPath $WorkingDirectory
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
  foreach ($key in @($start.Environment.Keys)) {
    if ($key.StartsWith('FLOWTRACE_') -or $key.StartsWith('PG') -or $key -in @('PYTHONPATH','PYTHONHOME')) { $null=$start.Environment.Remove($key) }
  }
  return [Diagnostics.Process]::Start($start)
}

function Invoke-LocalChild([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory) {
  $process = Start-LocalChild $Executable $Arguments $WorkingDirectory
  try{
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw 'local_test_child_failed' }
  }finally{$process.Dispose()}
}

function Start-AppComponent($Config,[ValidateSet('serve','worker')]$Mode) {
  $configPath=Join-Path $Config.root 'private/service.json'
  $python=Join-Path $Config.version_directory 'venv/Scripts/python.exe'
  $child=Start-LocalChild $python @('-I','-m','flowtrace_server.tools.local_test_service','--config',$configPath,'--service-id',$Config.service_id,'--mode',$Mode) $Config.root
  $markers=@($configPath,$Config.service_id)
  $records=@(Get-ProcessRecord $child.Id $markers)
  # A Windows venv redirector can own a base-python child. Track both identities.
  $deadline=[DateTime]::UtcNow.AddSeconds(2)
  do {
    $children=@(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($child.Id)")
    foreach($item in $children) {
      if($item.CommandLine -and $item.CommandLine.Contains($configPath) -and $item.CommandLine.Contains($Config.service_id)) {
        $records+=Get-ProcessRecord $item.ProcessId $markers
      }
    }
    if($children.Count -gt 0 -or $child.HasExited){break}
    Start-Sleep -Milliseconds 50
  }while([DateTime]::UtcNow -lt $deadline)
  if($child.HasExited){throw 'local_test_component_exited'}
  $prepared=Get-Prepared $Config.root $Config.version
  foreach($item in $records){if($item.exe -notin @($python,$prepared.python_base)){throw 'local_test_component_executable_mismatch'}}
  Write-LocalJson (Join-Path $Config.root "private/$Mode-process.json") @{service_id=$Config.service_id;records=$records}
}

function Stop-AppComponent($Config,[ValidateSet('serve','worker','supervisor')]$Mode) {
  $path=Join-Path $Config.root "private/$Mode-process.json"
  if(-not(Test-Path -LiteralPath $path)){return}
  $state=Read-LocalJson $path
  if($state.service_id -ne $Config.service_id){throw 'local_test_process_owner_mismatch'}
  foreach($record in @($state.records)) {
    $live=Get-Process -Id $record.pid -ErrorAction SilentlyContinue
    if($live -and -not(Test-OwnedProcess $record)){throw 'local_test_process_refused'}
  }
  [IO.File]::WriteAllText((Join-Path $Config.root "private/$Mode.stop"),$Config.service_id)
  $deadline=[DateTime]::UtcNow.AddSeconds(35)
  do{
    $remaining=@($state.records | Where-Object { Get-Process -Id $_.pid -ErrorAction SilentlyContinue })
    if($remaining.Count -eq 0){return}
    foreach($record in $remaining){if(-not(Test-OwnedProcess $record)){throw 'local_test_process_refused'}}
    Start-Sleep -Milliseconds 100
  }while([DateTime]::UtcNow -lt $deadline)
  throw 'local_test_component_stop_timeout'
}

function Clear-ComponentStop($Config,[string]$Mode) {
  $path=Get-PlainPath (Join-Path $Config.root "private/$Mode.stop")
  if(Test-Path -LiteralPath $path){
    if((Get-Content -LiteralPath $path -Raw) -ne $Config.service_id){throw 'local_test_stop_owner_mismatch'}
    Remove-Item -LiteralPath $path
  }
}

function Start-LocalDatabase($Config) {
  $data=Get-PlainPath (Join-Path $Config.root 'postgresql/data')
  $pidFile=Join-Path $data 'postmaster.pid'
  if(Test-Path -LiteralPath $pidFile){
    $statePath=Join-Path $Config.root 'private/database-process.json'
    if(Test-Path -LiteralPath $statePath){
      $state=Read-LocalJson $statePath
      if($state.service_id -eq $Config.service_id -and (Test-OwnedProcess $state.record)){return}
    }
    $lines=Get-Content -LiteralPath $pidFile
    if(-not(Test-Path -LiteralPath $statePath)){throw 'local_test_database_identity_unconfirmed'}
    if($state.service_id -ne $Config.service_id -or [int]$lines[0] -ne $state.record.pid -or (Get-PlainPath $lines[1]) -ne $data -or (Get-Process -Id $state.record.pid -ErrorAction SilentlyContinue)){throw 'local_test_database_identity_unconfirmed'}
  }
  Assert-PortFree $Config.database_port
  Reset-PostgresBootstrapLog $Config
  $bin=Join-Path $Config.version_directory 'postgresql/bin'
  $marker='flowtrace_'+$Config.service_id.Replace('-','')
  $options="-h 127.0.0.1 -p $($Config.database_port) -c cluster_name=$marker"
  Invoke-LocalChild (Join-Path $bin 'pg_ctl.exe') @('start','-D',$data,'-l',(Join-Path $Config.root 'data/postgresql-bootstrap.log'),'-o',$options,'-w','-t','30') $Config.root
  $pgId=[int](Get-Content -LiteralPath $pidFile -TotalCount 1)
  $record=Get-ProcessRecord $pgId @($data,$marker)
  if($record.exe -ne (Join-Path $bin 'postgres.exe')){throw 'local_test_database_executable_mismatch'}
  Write-LocalJson (Join-Path $Config.root 'private/database-process.json') @{service_id=$Config.service_id;record=$record}
}

function Stop-LocalDatabase($Config) {
  $path=Join-Path $Config.root 'private/database-process.json'
  if(-not(Test-Path -LiteralPath $path)){return}
  $state=Read-LocalJson $path
  $pidFile=Join-Path $Config.root 'postgresql/data/postmaster.pid'
  if($state.service_id -ne $Config.service_id){throw 'local_test_database_stop_refused'}
  $live=Get-Process -Id $state.record.pid -ErrorAction SilentlyContinue
  if(-not $live -and -not(Test-Path -LiteralPath $pidFile)){return}
  if($live){$live.Dispose()}
  if(-not(Test-OwnedProcess $state.record)){throw 'local_test_database_stop_refused'}
  if([int](Get-Content -LiteralPath $pidFile -TotalCount 1) -ne $state.record.pid){throw 'local_test_database_stop_refused'}
  Invoke-LocalChild (Join-Path $Config.version_directory 'postgresql/bin/pg_ctl.exe') @('stop','-D',(Join-Path $Config.root 'postgresql/data'),'-m','fast','-w','-t','30') $Config.root
}

function Get-LogonTaskArguments($Config) {
  return '-NoProfile -NonInteractive -WindowStyle Hidden -File "'+(Join-Path $Config.version_directory 'management/Supervisor.ps1')+'" -ConfigPath "'+(Join-Path $Config.root 'private/service.json')+'" -ServiceId "'+$Config.service_id+'"'
}

function Test-OwnedLogonTask($Task,$Config,[string]$UserSid) {
  return $Task.TaskPath -eq '\' -and $Task.Principal.UserId -in @($UserSid,[Security.Principal.WindowsIdentity]::GetCurrent().Name) -and [string]$Task.Principal.RunLevel -in @('0','Limited') -and $Task.Actions.Count -eq 1 -and $Task.Actions[0].Execute -eq (Join-Path $PSHOME 'pwsh.exe') -and $Task.Actions[0].WorkingDirectory -eq $Config.root -and $Task.Actions[0].Arguments -ceq (Get-LogonTaskArguments $Config)
}

function Get-PostgresLoggingPolicy($Config) {
  $directory=(Get-PlainPath (Join-Path $Config.root 'data/postgresql-logs')).Replace('\','/').Replace("'","''")
  return @(
    '# FlowTrace local-test: time rotation, not a hard byte quota.'
    'logging_collector = on'
    "log_destination = 'stderr'"
    "log_directory = '$directory'"
    "log_filename = 'postgresql-%H.log'"
    'log_rotation_age = 60'
    'log_rotation_size = 0'
    'log_truncate_on_rotation = on'
    "log_timezone = 'Asia/Shanghai'"
    ''
  ) -join "`n"
}

function Assert-PostgresStoppedForLogReset($Config) {
  $rootPath=Get-PlainPath $Config.root
  $owner=Get-LocalOwner $rootPath
  if($owner.service_id -ne $Config.service_id){throw 'local_test_database_owner_mismatch'}
  $statePath=Join-Path $rootPath 'private/database-process.json'
  $state=if(Test-Path -LiteralPath $statePath){Read-LocalJson $statePath}else{$null}
  if($state){
    if($state.service_id -ne $Config.service_id){throw 'local_test_database_identity_unconfirmed'}
    $live=Get-Process -Id $state.record.pid -ErrorAction SilentlyContinue
    if($live){$live.Dispose();throw 'local_test_database_still_running'}
  }
  $data=Get-PlainPath (Join-Path $rootPath 'postgresql/data')
  $pidFile=Get-PlainPath (Join-Path $data 'postmaster.pid')
  if(Test-Path -LiteralPath $pidFile){
    $lines=Get-Content -LiteralPath $pidFile
    if(-not $state -or $lines.Count -lt 2 -or [int]$lines[0] -ne $state.record.pid -or (Get-PlainPath $lines[1]) -ne $data){throw 'local_test_database_identity_unconfirmed'}
  }
  Assert-PortFree $Config.database_port
}

function Initialize-PostgresLogging($Config) {
  Assert-PostgresStoppedForLogReset $Config
  $data=Get-PlainPath (Join-Path $Config.root 'postgresql/data')
  $policy=Get-PlainPath (Join-Path $data 'flowtrace-local-logging.conf')
  $configuration=Get-PlainPath (Join-Path $data 'postgresql.conf')
  if(Test-Path -LiteralPath $policy){throw 'local_test_database_log_policy_exists'}
  if(-not(Test-Path -LiteralPath $configuration -PathType Leaf)){throw 'local_test_database_configuration_missing'}
  $null=New-Item -ItemType Directory -Path (Get-PlainPath (Join-Path $Config.root 'data/postgresql-logs'))
  [IO.File]::WriteAllText($policy,(Get-PostgresLoggingPolicy $Config),[Text.UTF8Encoding]::new($false))
  [IO.File]::AppendAllText($configuration,"`ninclude = 'flowtrace-local-logging.conf'`n",[Text.UTF8Encoding]::new($false))
}

function Reset-PostgresBootstrapLog($Config) {
  Assert-PostgresStoppedForLogReset $Config
  $data=Get-PlainPath (Join-Path $Config.root 'postgresql/data')
  $policy=Get-PlainPath (Join-Path $data 'flowtrace-local-logging.conf')
  $configuration=Get-PlainPath (Join-Path $data 'postgresql.conf')
  if((Get-Content -LiteralPath $policy -Raw) -cne (Get-PostgresLoggingPolicy $Config) -or -not(Get-Content -LiteralPath $configuration -Raw).Contains("include = 'flowtrace-local-logging.conf'")){throw 'local_test_database_log_policy_mismatch'}
  $log=Get-PlainPath (Join-Path $Config.root 'data/postgresql-bootstrap.log')
  [FlowTraceLocalLogFile]::Reset($log)
}
