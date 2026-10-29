$ErrorActionPreference='Stop'
$app=Split-Path $PSScriptRoot -Parent
$root=Join-Path ([IO.Path]::GetTempPath()) ('gn-desktop-'+[Guid]::NewGuid().ToString('N'))
$fixture=Join-Path $root 'app';$data=Join-Path $root 'state'
$null=[IO.Directory]::CreateDirectory($fixture);$null=[IO.Directory]::CreateDirectory($data)
$checks=0
function Assert([bool]$Value,[string]$Name){if(!$Value){throw $Name};$script:checks++}
try{
 foreach($directory in @('runtime','assets')){Copy-Item -LiteralPath (Join-Path $app $directory) -Destination $fixture -Recurse}
 foreach($name in @('widget.ps1','widget.xaml')){Copy-Item -LiteralPath (Join-Path $app $name) -Destination $fixture}
 [IO.File]::WriteAllText((Join-Path $fixture 'installation.json'),(@{appDir=$fixture;dataDir=$data}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 $fixtureSettings=Join-Path $data 'settings.json'
 [IO.File]::WriteAllText($fixtureSettings,'{"followHost":false,"desktopTopmost":false,"desktopLeft":100000,"desktopTop":100000,"soundOn":false,"scale":0.6,"bubbleScale":2.5,"layoutVersion":2}',[Text.UTF8Encoding]::new($false))
 $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($fixtureSettings))
 $source=[IO.File]::ReadAllText((Join-Path $fixture 'widget.ps1'),[Text.Encoding]::UTF8)
 $null=. ([ScriptBlock]::Create($source)) -AppDir $fixture -CheckOnly
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
 $tick=$ast.Find({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-eq 'Tick-Widget'},$true)
 . ([ScriptBlock]::Create($tick.Extent.Text))
 # Keep the complete placement implementation and real WPF/native windows;
 # replace services unrelated to placement so this cannot query user accounts.
 function Tick-Scene{};function Tick-WidgetUpdater{};function Ensure-QuotaWorker{}
 function Request-Refresh{};function Reset-WidgetAutoQuoteSchedule{}
 function Update-WidgetMusicPlacement{};function Update-WidgetMusicVisibility{}
 function Write-WidgetPresence{};function Update-Quota{};function Read-DisplayRequest{}
 function Tick-CompletionNotifications{};function Tick-WidgetAutoQuote{}
 function Test-WidgetHostReady{return $false}
 $script:widgetHandle=[Windows.Interop.WindowInteropHelper]::new($script:window).EnsureHandle()
 $script:hostFollower=[GptWidgetHostFollower]::new($script:widgetHandle)
 $script:occlusionRecovery=[GptWidgetOcclusionRecovery]::new($script:widgetHandle)
 $script:hostHandle=[IntPtr]::Zero;$script:attachedHost=[IntPtr]::Zero
 $script:hostReadiness.desktopStarted=$true
 Assert (!$script:window.IsVisible) 'Fixture was shown before its cold-start tick'
 for($cycle=0;$cycle-lt 4;$cycle++){
  if($cycle){$script:window.Hide();$script:lastPosition='cached'}
  Tick-Widget
  Assert $script:window.IsVisible 'Desktop cold start or hidden recovery did not show the widget'
  Tick-Widget
  Assert (!$script:desktopPositionPending) 'Connected desktop position was not replayed'
  $frame=Get-WidgetPlacementFrame
  $girl=$script:ui.Girl
  $a=$girl.PointToScreen([Windows.Point]::new(0,0));$b=$girl.PointToScreen([Windows.Point]::new($girl.ActualWidth,$girl.ActualHeight))
  Assert ([Math]::Min($a.X,$b.X)-ge $frame.Left-2-and [Math]::Max($a.X,$b.X)-le $frame.Right+2) 'Restored character is horizontally outside the work area'
  Assert ([Math]::Min($a.Y,$b.Y)-ge $frame.Top-2-and [Math]::Max($a.Y,$b.Y)-le $frame.Bottom+2) 'Restored character is vertically outside the work area'
  Assert ($script:desktopLeft-eq 100000-and $script:desktopTop-eq 100000) 'Cold-start fit overwrote requested desktop coordinates'
 }
 Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixtureSettings))-ceq $before) 'Cold start rewrote personal settings'
 Write-Output ('PASS: '+$checks+' actual desktop cold-start/hidden-recovery and saved-position assertions')
}finally{
 if($script:occlusionRecovery){$script:occlusionRecovery.Dispose()}
 if($script:hostFollower){$script:hostFollower.Dispose()}
 if($script:window){$script:window.Close()}
 $resolved=[IO.Path]::GetFullPath($root)
 if(!$resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe desktop fixture cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
