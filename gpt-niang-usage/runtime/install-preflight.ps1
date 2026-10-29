function Test-WidgetWritableDirectory([string]$Directory) {
  $existing=$Directory
  while(!(Test-Path -LiteralPath $existing)){$existing=Split-Path $existing -Parent;if(!$existing){throw 'Writable parent directory unavailable.'}}
  $probe=Join-Path $existing ('.gpt-niang-write-'+[Guid]::NewGuid().ToString('N'))
  try{$stream=[IO.File]::Open($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$stream.Dispose()}
  finally{if([IO.File]::Exists($probe)){[IO.File]::Delete($probe)}}
}
function Assert-WidgetNoReparsePoint([string]$Directory) {
  for($current=[IO.Path]::GetFullPath($Directory);$current;$current=Split-Path $current -Parent){
    if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes-band [IO.FileAttributes]::ReparsePoint)){throw 'Installation or update paths may not contain links.'}
  }
}
function Invoke-WidgetCodexReadOnly {
  param([string]$Codex,[string]$Arguments,[ValidateRange(1,2147483647)][int]$TimeoutMilliseconds=8000)
  $start=[Diagnostics.ProcessStartInfo]::new()
  $start.FileName=$Codex;$start.Arguments=$Arguments;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
  $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
  $process=[Diagnostics.Process]::new();$process.StartInfo=$start
  $stdout=$null;$stderr=$null
  $watch=[Diagnostics.Stopwatch]::StartNew()
  try{
    if(!$process.Start()){throw 'Cannot start Codex.'}
    $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
    $remaining=[Math]::Max(0,$TimeoutMilliseconds-[int]$watch.ElapsedMilliseconds)
    $exited=$process.WaitForExit($remaining)
    $remaining=[Math]::Max(0,$TimeoutMilliseconds-[int]$watch.ElapsedMilliseconds)
    # Descendants can inherit the pipes after the CLI itself exits. Both reads
    # must finish within the same deadline as the process, not an extra timeout.
    if(!$exited -or ![Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),$remaining)){
      if(!$process.HasExited){$process.Kill()}
      throw ('Codex read-only command timed out: '+$Arguments)
    }
    return [pscustomobject]@{exitCode=$process.ExitCode;output=$stdout.Result;error=$stderr.Result}
  }finally{
    try{if($stdout){$process.StandardOutput.Close()}}
    finally{try{if($stderr){$process.StandardError.Close()}}finally{$process.Dispose()}}
  }
}
function Test-WidgetCodexCapabilities([string]$Path){
  if(!(Test-Path -LiteralPath $Path -PathType Leaf)){return $false}
  foreach($command in @('plugin marketplace add --help','plugin add --help','plugin list --help')){
    try{$result=Invoke-WidgetCodexReadOnly $Path $command}catch{return $false}
    if($result.exitCode-ne 0-or $result.output-notmatch '(?m)--json\b'){return $false}
    if($command-eq 'plugin list --help'-and $result.output-notmatch '(?m)--marketplace\b'){return $false}
  }
  return $true
}
function Resolve-WidgetInstallCodex {
  param([string]$LocalData,[string[]]$Candidates)
  $paths=[Collections.Generic.List[string]]::new()
  if($PSBoundParameters.ContainsKey('Candidates')){
    foreach($path in $Candidates){$paths.Add($path)}
  }else{
    if($env:CODEX_CLI_PATH){$paths.Add($env:CODEX_CLI_PATH)}
    try{foreach($process in @(Get-CimInstance Win32_Process -Filter "Name='codex.exe'" -ErrorAction Stop)){if($process.ExecutablePath){$paths.Add([string]$process.ExecutablePath)}}}catch{}
    foreach($command in @(Get-Command codex.exe -All -ErrorAction SilentlyContinue)){if($command.Source){$paths.Add($command.Source)}}
    $bundled=Join-Path $LocalData 'OpenAI\Codex\bin'
    if(Test-Path -LiteralPath $bundled){
      foreach($file in @(Get-ChildItem -LiteralPath $bundled -Filter codex.exe -File -Recurse -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending)){$paths.Add($file.FullName)}
    }
  }
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($path in $paths){
    if(!$path-or !$seen.Add([IO.Path]::GetFullPath($path))){continue}
    if(Test-WidgetCodexCapabilities $path){return [IO.Path]::GetFullPath($path)}
  }
  throw ('No compatible Codex CLI supports plugin marketplace add/add/list --json and scoped marketplace verification. Candidates checked: '+($seen-join '; '))
}
function Get-WidgetInstallPreflight {
  param([Parameter(Mandatory=$true)][string]$SourceDir,[Parameter(Mandatory=$true)][string]$AppDir)
  $appDir=[IO.Path]::GetFullPath($AppDir).TrimEnd('\');$sourceDir=[IO.Path]::GetFullPath($SourceDir).TrimEnd('\')
  $programRoot=Split-Path $appDir -Parent;$agentDir=[IO.Path]::GetFullPath((Get-WidgetUpdateAgentDir)).TrimEnd('\')
  if($agentDir-ieq $programRoot -or $agentDir.StartsWith($programRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or $programRoot.StartsWith($agentDir+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Stable update launcher must be outside the program directory.'}
  $localData=Get-WidgetLocalApplicationData
  if(!$localData){throw 'Local application data folder unavailable.'}
  $dataDir=Join-Path $localData 'GPTNiangUsage\state'
  $previousConfig=Join-Path $appDir 'installation.json'
  if(Test-Path -LiteralPath $previousConfig){$previous=Read-WidgetUpdateJson $previousConfig;$dataDir=Get-WidgetInstallationDataDir -AppDir $appDir -Configuration $previous}
  $dataDir=[IO.Path]::GetFullPath($dataDir).TrimEnd('\')
  if($appDir-ieq $dataDir -or $appDir.StartsWith($dataDir+'\',[StringComparison]::OrdinalIgnoreCase) -or $dataDir.StartsWith((Join-Path $appDir 'runtime')+'\',[StringComparison]::OrdinalIgnoreCase) -or $dataDir-ieq (Join-Path $appDir 'runtime')){throw 'Data directory overlaps program files.'}
  $nodeCommand=Get-Command node.exe -ErrorAction SilentlyContinue
  if(!$nodeCommand){throw 'Node.js 20 or later is required. Install Node.js and reopen the installer.'}
  $node=$nodeCommand.Source
  $nodeMajor=[int]((& $node --version).TrimStart('v').Split('.')[0])
  if($nodeMajor-lt 20){throw 'Node.js 20 or later is required.'}
  $codex=Resolve-WidgetInstallCodex -LocalData $localData
  $required=Read-WidgetUpdateJson (Join-Path $sourceDir 'runtime\install-files.json')
  if(!$required){throw 'Missing installation file list.'}
  foreach($file in $required){if(!(Test-Path -LiteralPath (Join-Path $sourceDir $file) -PathType Leaf)){throw ('Missing file: '+$file.Replace('/','\'))}}
  foreach($path in @($appDir,$sourceDir,$dataDir,(Get-WidgetUpdateAgentDir))){Assert-WidgetNoReparsePoint $path}
  $manifest=Read-WidgetUpdateJson (Join-Path $sourceDir '.codex-plugin\plugin.json')
  $package=Read-WidgetUpdateJson (Join-Path $sourceDir 'package.json')
  if(!$manifest.version -or $manifest.version-ne $package.version -or $manifest.version-notmatch '^\d+\.\d+\.\d+$'){throw 'Package version mismatch.'}
  if(!(Test-Path -LiteralPath (Join-Path (Split-Path $sourceDir -Parent) '.agents\plugins\marketplace.json'))){throw 'Marketplace metadata missing.'}
  $startup=Get-WidgetKnownFolderPath ([Guid]'B97D20BB-F46A-4C97-BA10-5E3608430854');if(!$startup){throw 'Windows Startup folder unavailable.'}
  $shortcut=Join-Path $startup 'GPT Niang Usage.lnk'
  $config=@{version=$manifest.version;appDir=$appDir;dataDir=$dataDir;nodePath=$node;codexPath=$codex;marketplaceRoot=(Split-Path $appDir -Parent);startupShortcut=$shortcut;installedAt=[DateTime]::UtcNow.ToString('o');updateAgent=(Get-WidgetUpdateAgentDir);updaterSchema=1}
  $localBuild=Read-WidgetUpdateJson (Join-Path $sourceDir 'local-build.json')
  if($localBuild.id){$config.localBuild=[string]$localBuild.id}
  $info=Get-WidgetSupervisorInfo -AppDir $appDir -Configuration $config
  $null=Get-WidgetSupervisorTask $info
  if(Test-Path -LiteralPath $shortcut){
    $existing=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
    if(!(Test-WidgetStartupShortcutIdentity -Shortcut $existing -AppDir $appDir)){throw 'Existing shortcut belongs to another installation.'}
  }
  $binding=Read-WidgetUpdateJson (Join-Path (Get-WidgetUpdateAgentDir) 'binding.json')
  if($binding -and $binding.appDir-ine $appDir -and (Test-Path -LiteralPath $binding.appDir)){throw 'Stable launcher belongs to another installation.'}
  foreach($directory in @($appDir,(Split-Path (Split-Path $appDir -Parent) -Parent),$dataDir,$startup,(Get-WidgetUpdateAgentDir))){Test-WidgetWritableDirectory $directory}
  return $config
}
function Assert-WidgetPluginRegistration([string]$Codex,[string]$Version) {
  $result=Invoke-WidgetCodexReadOnly $Codex 'plugin list --marketplace gpt-niang-local --json' 30000
  if($result.exitCode-ne 0){throw ('Plugin registration query failed; registration may already exist. '+$result.error)}
  $catalog=$result.output|ConvertFrom-Json
  $match=@($catalog.installed|Where-Object{$_.pluginId-eq 'gpt-niang-usage@gpt-niang-local' -and $_.version-eq $Version -and $_.installed -and $_.enabled})
  if($match.Count-ne 1){throw 'Codex did not report one enabled GPT Niang plugin.'}
}
