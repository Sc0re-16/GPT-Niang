param([string]$TestRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
$script:assertions=0
function Assert-Lifecycle([bool]$Condition,[string]$Message){
  if(!$Condition){throw $Message}
  $script:assertions++
}
function Wait-TestWorker([int]$ExpectedPid){
  $deadline=[DateTime]::UtcNow.AddSeconds(3)
  do{
    try{
      $health=Get-Content -LiteralPath (Join-Path $script:dataDir 'worker-status.json') -Raw -Encoding UTF8|ConvertFrom-Json
      if($health.pid-eq $ExpectedPid){return $health}
    }catch{}
    Start-Sleep -Milliseconds 50
  }while([DateTime]::UtcNow-lt $deadline)
  $exited=if($script:worker){try{$script:worker.HasExited}catch{$true}}else{$true}
  throw ('Dummy worker did not publish its heartbeat for PID '+$ExpectedPid+' (exited='+$exited+').')
}

# Load only lifecycle functions; never create the real WPF UI or read its config.
$widgetFile=Join-Path (Split-Path $TestRoot -Parent) 'widget.ps1'
$source=[IO.File]::ReadAllText($widgetFile,[Text.Encoding]::UTF8)
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'The widget source has PowerShell parse errors.'}
foreach($functionName in @('Ensure-QuotaWorker','Stop-WidgetRuntime')){
  $definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-eq $functionName},$true)
  if(!$definition){throw ('Missing lifecycle function: '+$functionName)}
  . ([scriptblock]::Create($definition.Extent.Text))
}

$testDir=Join-Path ([IO.Path]::GetTempPath()) ('gpt-widget-lifecycle-'+[Guid]::NewGuid().ToString('N'))
$script:appDir=$testDir
$script:dataDir=Join-Path $testDir 'data'
$runtimeDir=Join-Path $testDir 'runtime'
$script:configPath=Join-Path $testDir 'installation.json'
$script:worker=$null;$script:mutex=$null;$script:mutexOwned=$false
$script:lastWorkerProbe=0;$script:lastWorkerStart=0;$script:runtimeClosed=$false
$script:eventHooks=@()
$mutexName='Local\GPTNiangLifecycleTest-'+[Guid]::NewGuid().ToString('N')
try{
  $null=[IO.Directory]::CreateDirectory($script:dataDir)
  $null=[IO.Directory]::CreateDirectory($runtimeDir)
  $script:config=[pscustomobject]@{nodePath=(Get-Command node -ErrorAction Stop).Source;dataDir=$script:dataDir}
  [IO.File]::WriteAllText($script:configPath,($script:config|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
  $dummy=@'
import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
const config=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const owner={pid:process.pid,parentPid:Number(process.argv[3]),token:randomUUID(),startedAt:Date.now()};
fs.writeFileSync(path.join(config.dataDir,'worker.lock'),JSON.stringify(owner));
function heartbeat(){
  const file=path.join(config.dataDir,'worker-status.json'),temp=file+'.'+process.pid+'.tmp';
  try{fs.writeFileSync(temp,JSON.stringify({...owner,at:Date.now()}));fs.renameSync(temp,file);}
  catch{try{fs.unlinkSync(temp);}catch{}}
}
heartbeat();
setInterval(()=>{if(!fs.existsSync(path.join(config.dataDir,'pause-heartbeat.flag')))heartbeat();},100);
'@
  [IO.File]::WriteAllText((Join-Path $runtimeDir 'watch.mjs'),$dummy,[Text.UTF8Encoding]::new($false))
  $script:mutex=[Threading.Mutex]::new($true,$mutexName)
  $script:mutexOwned=$true
  $script:timer=[pscustomobject]@{}
  $script:timer|Add-Member -MemberType ScriptMethod -Name Stop -Value {throw 'Injected timer stop failure.'}
  function Stop-WidgetAudio {throw 'Injected audio stop failure.'}

  Ensure-QuotaWorker ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  if(!$script:worker){throw 'The dummy quota worker was not launched.'}
  $firstPid=$script:worker.Id
  $health=Wait-TestWorker $firstPid
  Assert-Lifecycle ($health.parentPid-eq $PID) 'The parent PID was not passed to the worker.'

  $script:lastWorkerProbe=0
  Ensure-QuotaWorker ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  Assert-Lifecycle ($script:worker.Id-eq $firstPid) 'A healthy worker was duplicated.'

  # Tick-Widget captures its time before Ensure-QuotaWorker reads the heartbeat.
  # A later, valid heartbeat must not be mistaken for a future/stale worker.
  $tickBeforeHeartbeat=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $deadline=[DateTime]::UtcNow.AddSeconds(3)
  do{
    $health=Wait-TestWorker $firstPid
    if([long]$health.at-gt $tickBeforeHeartbeat){break}
    Start-Sleep -Milliseconds 25
  }while([DateTime]::UtcNow-lt $deadline)
  if([long]$health.at-le $tickBeforeHeartbeat){throw 'Dummy worker did not publish a newer heartbeat.'}
  $script:lastWorkerProbe=0;$script:lastWorkerStart=$tickBeforeHeartbeat-11000
  Ensure-QuotaWorker $tickBeforeHeartbeat
  Assert-Lifecycle ($script:worker.Id-eq $firstPid -and !$script:worker.HasExited) 'A heartbeat newer than the tick caused a healthy worker restart.'

  # Truly stale or future-dated records must still trigger recovery.
  foreach($offset in @(-6000,60000)){
    $pauseFile=Join-Path $script:dataDir 'pause-heartbeat.flag'
    [IO.File]::WriteAllText($pauseFile,'pause')
    Start-Sleep -Milliseconds 350
    $health=Wait-TestWorker $firstPid
    $health.at=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()+$offset
    [IO.File]::WriteAllText((Join-Path $script:dataDir 'worker-status.json'),($health|ConvertTo-Json -Compress))
    $probe=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $script:lastWorkerProbe=0;$script:lastWorkerStart=$probe-11000
    Ensure-QuotaWorker $probe
    Assert-Lifecycle ($script:worker -and $script:worker.Id-ne $firstPid) 'An invalid heartbeat did not trigger worker recovery.'
    $firstPid=$script:worker.Id
    [IO.File]::Delete($pauseFile)
    $null=Wait-TestWorker $firstPid
  }

  $script:worker.Kill()
  $null=$script:worker.WaitForExit(2000)
  $script:lastWorkerProbe=0;$script:lastWorkerStart=0
  Ensure-QuotaWorker ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
  Assert-Lifecycle ($script:worker -and $script:worker.Id-ne $firstPid) 'An exited worker was not restarted.'
  $restartedPid=$script:worker.Id
  $null=Wait-TestWorker $restartedPid

  [IO.File]::WriteAllText((Join-Path $script:dataDir 'runtime.json'),('{"pid":'+$PID+'}'))
  [IO.File]::WriteAllText((Join-Path $script:dataDir 'presence.json'),'{"pid":2147483647}')
  Stop-WidgetRuntime
  Stop-WidgetRuntime
  $deadline=[DateTime]::UtcNow.AddSeconds(2)
  do{
    $remaining=Get-Process -Id $restartedPid -ErrorAction SilentlyContinue
    if(!$remaining){break}
    $remaining.Dispose()
    Start-Sleep -Milliseconds 50
  }while([DateTime]::UtcNow-lt $deadline)
  Assert-Lifecycle (!$remaining) 'Cleanup left its own worker running after injected failures.'
  Assert-Lifecycle (!(Test-Path -LiteralPath (Join-Path $script:dataDir 'runtime.json')) -and (Test-Path -LiteralPath (Join-Path $script:dataDir 'presence.json'))) 'Cleanup removed another owner record or retained its own record.'
  Assert-Lifecycle $script:runtimeClosed 'Cleanup was not idempotent.'
  $observer=[Threading.Mutex]::new($false,$mutexName)
  try{
    $released=$observer.WaitOne(0)
    if($released){$observer.ReleaseMutex()}
    Assert-Lifecycle $released 'Cleanup leaked its mutex.'
  }finally{$observer.Dispose()}
  Write-Output ('Lifecycle assertions passed: '+$script:assertions)
}finally{
  if($script:worker){
    try{if(!$script:worker.HasExited){$script:worker.Kill();$null=$script:worker.WaitForExit(2000)}}catch{}
    try{$script:worker.Dispose()}catch{}
  }
  try{if($script:mutexOwned){$script:mutex.ReleaseMutex()};if($script:mutex){$script:mutex.Dispose()}}catch{}
  foreach($directory in @($script:dataDir,$runtimeDir)){
    if([IO.Directory]::Exists($directory)){
      foreach($file in [IO.Directory]::GetFiles($directory)){[IO.File]::Delete($file)}
      [IO.Directory]::Delete($directory)
    }
  }
  if([IO.File]::Exists($script:configPath)){[IO.File]::Delete($script:configPath)}
  if([IO.Directory]::Exists($testDir)){[IO.Directory]::Delete($testDir)}
}
