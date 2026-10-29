param([int]$Iterations=10000,[string]$ResultFile)
$ErrorActionPreference='Stop'
$app=Split-Path $PSScriptRoot -Parent
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('gn-quota-memory-'+[Guid]::NewGuid().ToString('N'))
$fixtureApp=Join-Path $fixtureRoot 'app';$fixtureData=Join-Path $fixtureRoot 'state'
$null=[IO.Directory]::CreateDirectory($fixtureApp);$null=[IO.Directory]::CreateDirectory($fixtureData)
try{
 foreach($directory in @('runtime','assets')){Copy-Item -LiteralPath (Join-Path $app $directory) -Destination $fixtureApp -Recurse}
 foreach($name in @('widget.ps1','widget.xaml')){Copy-Item -LiteralPath (Join-Path $app $name) -Destination $fixtureApp}
 [IO.File]::WriteAllText((Join-Path $fixtureApp 'installation.json'),(@{appDir=$fixtureApp;dataDir=$fixtureData}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((Join-Path $fixtureData 'settings.json'),'{"soundOn":false,"followHost":false}',[Text.UTF8Encoding]::new($false))
 $quota=@{ok=$true;queryOk=$true;planLabel='Synthetic';windows=@(@{minutes=300;used=25;remaining=75;resetsAt=2000000000},@{minutes=10080;used=10;remaining=90;resetsAt=2001000000})}
 [IO.File]::WriteAllText((Join-Path $fixtureData 'status.json'),($quota|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
 $text=[IO.File]::ReadAllText((Join-Path $fixtureApp 'widget.ps1'),[Text.Encoding]::UTF8)
 $null=. ([ScriptBlock]::Create($text)) -AppDir $fixtureApp -CheckOnly
 for($i=0;$i-lt 500;$i++){Update-Quota}
 $process=[Diagnostics.Process]::GetCurrentProcess();$process.Refresh()
 $initial=$process.PrivateMemorySize64;$peak=$initial;$samples=@()
 $beforeTypes=@($script:status.windows|ForEach-Object {$_.PSObject.TypeNames.Count})
 for($i=1;$i-le $Iterations;$i++){
  Update-Quota
  if($i%250-eq 0){
   $process.Refresh();$peak=[Math]::Max($peak,$process.PrivateMemorySize64)
   $samples+=@{iteration=$i;privateMiB=$process.PrivateMemorySize64/1MB;managedMiB=[GC]::GetTotalMemory($false)/1MB;types=@($script:status.windows|ForEach-Object {$_.PSObject.TypeNames.Count})}
   if($process.PrivateMemorySize64-$initial-gt 128MB){throw 'Quota refresh retained more than 128 MiB after warm-up'}
  }
 }
 $afterTypes=@($script:status.windows|ForEach-Object {$_.PSObject.TypeNames.Count})
 if(($beforeTypes-join ',')-cne ($afterTypes-join ',')){throw 'Cached quota metadata continued growing'}
 $result=@{passed=$true;iterations=$Iterations;warmup=500;initialPrivateMiB=$initial/1MB;peakPrivateMiB=$peak/1MB;lastPrivateMiB=$samples[-1].privateMiB;metadataBefore=$beforeTypes;metadataAfter=$afterTypes;forcedGarbageCollection=$false;realUserDataRead=$false;samples=$samples}
 if($ResultFile){[IO.File]::WriteAllText($ResultFile,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
 Write-Output ('PASS: '+$Iterations+' complete WPF quota refreshes; private MiB '+[Math]::Round($initial/1MB,2)+' -> '+[Math]::Round($samples[-1].privateMiB,2)+'; metadata '+($afterTypes-join ',')+'; no forced GC')
 $process.Dispose()
}finally{
 if($script:window){$script:window.Close()}
 $resolved=[IO.Path]::GetFullPath($fixtureRoot)
 if(!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe memory fixture cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
