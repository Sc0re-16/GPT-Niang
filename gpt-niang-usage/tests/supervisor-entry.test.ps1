$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
. (Join-Path $source 'runtime\update-helper.ps1') -FunctionsOnly
$root=Join-Path ([IO.Path]::GetTempPath()) ('gn-entry-'+[Guid]::NewGuid().ToString('N'))
$app=Join-Path $root 'app';$data=Join-Path $root 'state';$script:entryAgent=Join-Path $root 'agent'
foreach($p in @($app,$data,$script:entryAgent)){$null=[IO.Directory]::CreateDirectory($p)}
function Get-WidgetUpdateAgentDir{return $script:entryAgent}
$checks=0
function Assert([bool]$Value,[string]$Name){if(!$Value){throw $Name};$script:checks++}
function Reject([scriptblock]$Action,[string]$Name){try{& $Action|Out-Null}catch{$script:checks++;return};throw $Name}
try{
 $config=@{appDir=$app;dataDir=$data;updateAgent=$script:entryAgent;codexPath='fixture';version='1.3.5'}
 Write-WidgetSupervisorJson (Join-Path $app 'installation.json') $config
 $info=Get-WidgetSupervisorInfo $app
 Write-WidgetSupervisorJson (Join-Path $script:entryAgent 'binding.json') @{sid=$info.Sid;appDir=$app;dataDir=$data}
 Assert ($info.Execute-ieq (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')) 'Task still depends on WScript'
 Assert ($info.WorkingDirectory-ieq (Join-Path $env:WINDIR 'System32')) 'Task relies on the potentially redirected agent working directory'
 Assert ($info.Arguments.Contains('-File "'+(Join-Path $script:entryAgent 'update-agent.ps1')+'" -Supervisor')) 'Direct entry path changed'
 $script:entryTask=[pscustomobject]@{TaskName=$info.TaskName;TaskPath=$info.TaskPath;State='Running';Principal=@{UserId=$info.Sid;LogonType='Interactive';RunLevel='Limited'};Actions=@(@{Execute=$info.Execute;Arguments=$info.Arguments;WorkingDirectory=$info.WorkingDirectory})}
 Assert-WidgetSupervisorTaskIdentity $script:entryTask $info;$checks++
 $shortcut=@{TargetPath=$info.Execute;Arguments=$info.Arguments}
 Assert (Test-WidgetStartupShortcutIdentity $shortcut $app) 'Independent direct-start shortcut rejected'
 $legacy=[pscustomobject]@{TaskName=$info.TaskName;TaskPath=$info.TaskPath;Principal=$script:entryTask.Principal;Actions=@(@{Execute=(Join-Path $env:WINDIR 'System32\wscript.exe');Arguments=('"'+(Join-Path $script:entryAgent 'agent-supervisor.vbs')+'"');WorkingDirectory=$script:entryAgent})}
 Assert-WidgetSupervisorTaskIdentity $legacy $info;$checks++
 $script:entryTask.Actions[0].Arguments+=' -File C:\foreign.ps1'
 Reject {Assert-WidgetSupervisorTaskIdentity $script:entryTask $info} 'Extra task arguments accepted'
 $script:entryTask.Actions[0].Arguments=$info.Arguments
 $script:entryTask.Principal.RunLevel='Highest'
 Reject {Assert-WidgetSupervisorTaskIdentity $script:entryTask $info} 'Elevated task accepted'
 $script:entryTask.Principal.RunLevel='Limited'
 function Get-CimInstance {param($ClassName,[string]$Filter)
  if($Filter-eq ('ProcessId='+$PID)){return [pscustomobject]@{ProcessId=$PID;Name='powershell.exe';CreationDate=$script:entryStarted;CommandLine=('powershell.exe '+(Get-WidgetAgentPowerShellArguments $script:entryAgent))}}
  return @()
 }
 function Get-ScheduledTask{return $script:entryTask}
 function Stop-ScheduledTask{throw 'Recovery entry attempted to stop its own task'}
 Stop-WidgetSupervisorTask $app;$checks++
 function Assert-WidgetPluginRegistration{}
 $script:entryStarted=(Get-Process -Id $PID).StartTime.ToUniversalTime()
 Write-WidgetSupervisorJson (Join-Path $data 'supervisor-status.json') @{pid=$PID;processStartedAt=$script:entryStarted.ToString('o');at=[DateTime]::UtcNow.ToString('o');paused=$false;widgetRunning=$false;visibleWindows=0}
 Wait-WidgetUpdatedHealth @{appDir=$app;dataDir=$data;version='1.3.5';installStartedAt=$script:entryStarted.AddSeconds(-1).ToString('o')};$checks++
 Write-Output ('PASS: '+$checks+' direct task, independent startup, legacy migration, recovery and updater health assertions')
}finally{
 $resolved=[IO.Path]::GetFullPath($root)
 if(!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe entry fixture cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
