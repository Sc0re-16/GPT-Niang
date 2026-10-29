$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime\update-helper.ps1') -FunctionsOnly
$script:app=Join-Path ([IO.Path]::GetTempPath()) 'health-fixture\app'
$script:agent=Join-Path ([IO.Path]::GetTempPath()) 'health-fixture\agent'
$journal=@{appDir=$script:app;dataDir=(Join-Path ([IO.Path]::GetTempPath()) 'health-fixture\state');version='1.3.5';installStartedAt=[DateTime]::UtcNow.AddSeconds(-2).ToString('o')}
$checks=0
function Assert([bool]$Value,[string]$Label){if(!$Value){throw $Label};$script:checks++}
function Accept([string]$Label){Wait-WidgetUpdatedHealth $journal -TimeoutMilliseconds 100;Assert $true $Label}
function Reject([string]$Label){try{Wait-WidgetUpdatedHealth $journal -TimeoutMilliseconds 25}catch{Assert ($_.Exception.Message-like 'Updated installation health*') $Label;return};throw ('Unexpected acceptance: '+$Label)}
function Get-WidgetUpdateAgentDir{return $script:agent}
function Assert-WidgetPluginRegistration([string]$Codex,[string]$Version){if($Codex-ne 'fixture'-or $Version-ne '1.3.5'){throw 'External CLI selected'}}
function Read-WidgetUpdateJson([string]$File){
  switch(Split-Path $File -Leaf){
    'installation.json' {return @{codexPath='fixture'}}
    'settings.json' {return $script:settings}
    'runtime.json' {return $script:runtime}
    'supervisor-status.json' {$script:reads++;if($script:readyAfter-and $script:reads-ge $script:readyAfter){$script:status.widgetRunning=$true};return $script:status}
    default {throw ('Unexpected observation: '+$File)}
  }
}
function Get-CimInstance {param($ClassName,[string]$Filter)
  switch($Filter){'ProcessId=901001' {return $script:supervisor};'ProcessId=901002' {return $script:gui}}
}
function Reset-Case {
  $created=[DateTime]::UtcNow.AddSeconds(-1)
  $script:settings=@{followHost=$true};$script:reads=0;$script:readyAfter=0
  $script:status=@{pid=901001;processStartedAt=$created.ToString('o');at=[DateTime]::UtcNow.ToString('o');paused=$false;widgetRunning=$true;visibleWindows=1;mainWindows=1}
  $script:supervisor=@{Name='powershell.exe';CreationDate=$created;CommandLine=('powershell.exe '+(Get-WidgetAgentPowerShellArguments $script:agent))}
  $script:gui=@{Name='powershell.exe';CreationDate=$created;CommandLine=('powershell.exe -File "'+(Join-Path $script:app 'widget.ps1')+'"')}
  $script:runtime=@{pid=901002;widget=42;startedAt=$created.ToString('o');processStartedAt=$created.ToString('o')}
}
Reset-Case;Accept 'new visible widget is ready'
Reset-Case;$script:supervisor.CreationDate=$script:supervisor.CreationDate.AddTicks(-9);$script:gui.CreationDate=$script:gui.CreationDate.AddTicks(-9);Accept 'CIM microsecond precision'
Reset-Case;$script:status.widgetRunning=$false;Reject 'visible host without a GUI'
Reset-Case;$script:settings.followHost=$false;$script:status.visibleWindows=0;$script:status.widgetRunning=$false;Reject 'desktop mode without a GUI'
Reset-Case;$script:settings.followHost=$false;$script:status.visibleWindows=0;Accept 'ready desktop with no host'
Reset-Case;$script:status.visibleWindows=0;$script:status.widgetRunning=$false;$script:runtime=$null;Accept 'hidden host without an unnecessary GUI'
Reset-Case;$script:status.paused=$true;$script:status.widgetRunning=$false;$script:runtime=$null;Accept 'user pause'
Reset-Case;$script:status.Remove('visibleWindows');Reject 'incomplete supervisor status'
Reset-Case;$script:status.at=[DateTime]::UtcNow.AddMinutes(1).ToString('o');Reject 'future heartbeat'
Reset-Case;$script:status.at=[DateTime]::UtcNow.AddMinutes(-1).ToString('o');Reject 'stale heartbeat'
Reset-Case;$script:supervisor.CreationDate=[DateTime]::UtcNow.AddMinutes(-1);Reject 'old supervisor reused after installation'
Reset-Case;$script:status.processStartedAt=[DateTime]::UtcNow.AddMinutes(-1).ToString('o');Reject 'reused supervisor PID'
Reset-Case;$script:supervisor.CommandLine='powershell.exe -File "C:\foreign.ps1"';Reject 'foreign supervisor path'
Reset-Case;$script:runtime.startedAt=[DateTime]::UtcNow.AddMinutes(-1).ToString('o');Reject 'old runtime receipt'
Reset-Case;$script:runtime.processStartedAt=[DateTime]::UtcNow.AddMinutes(-1).ToString('o');Reject 'reused widget PID'
Reset-Case;$script:runtime.widget=0;Reject 'uninitialized window'
Reset-Case;$script:gui.CommandLine='powershell.exe -File "C:\foreign.ps1"';Reject 'foreign widget path'
Reset-Case;$script:status.widgetRunning=$false;$script:readyAfter=2
Wait-WidgetUpdatedHealth $journal -TimeoutMilliseconds 1000;Assert ($script:reads-ge 2) 'slow startup is awaited'
Write-Output ('PASS: '+$checks+' update health identity, GUI readiness, hidden/pause and retry assertions')
