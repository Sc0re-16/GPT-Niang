$ErrorActionPreference='Stop'
$text=[IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime\host-ready.ps1'),[Text.Encoding]::UTF8)
$start=$text.IndexOf(' public static bool Poll(IntPtr handle){')
$end=$text.IndexOf(' public static bool HasInterface(IntPtr handle){',$start)
if($start-lt 0-or $end-le $start){throw 'Readiness algorithm missing'}
$source=@'
using System;using System.Threading;using System.Threading.Tasks;
public static class BoundedReadinessTest {
 static readonly object Gate=new object();static IntPtr target,pendingTarget;static Task<bool> pending;
 static readonly ManualResetEventSlim unblock=new ManualResetEventSlim(false);
 static int started,active,peak;
 public static int Started{get{return started;}}public static int Active{get{return active;}}public static int Peak{get{return peak;}}
 static Task<bool> StartProbe(IntPtr h){return Task.Factory.StartNew(()=>HasInterface(h),CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);}
 static bool HasInterface(IntPtr h){Interlocked.Increment(ref started);int n=Interlocked.Increment(ref active);peak=Math.Max(peak,n);try{unblock.Wait();return true;}finally{Interlocked.Decrement(ref active);}}
 public static void Release(){unblock.Set();}
'@+$text.Substring($start,$end-$start)+"`n}"
Add-Type -TypeDefinition $source
try{
 $null=[BoundedReadinessTest]::Poll([IntPtr]1)
 for($i=0;$i-lt 100-and [BoundedReadinessTest]::Started-eq 0;$i++){Start-Sleep -Milliseconds 10}
 for($i=2;$i-le 1000;$i++){$null=[BoundedReadinessTest]::Poll([IntPtr]$i)}
 if([BoundedReadinessTest]::Started-ne 1-or [BoundedReadinessTest]::Active-ne 1){throw 'Host changes created multiple blocked probes'}
 [BoundedReadinessTest]::Release()
 for($i=0;$i-lt 100-and [BoundedReadinessTest]::Active-ne 0;$i++){Start-Sleep -Milliseconds 10}
 if([BoundedReadinessTest]::Poll([IntPtr]1000)){throw 'Result for an old host was reused'}
 $ready=$false
 for($i=0;$i-lt 100-and !$ready;$i++){Start-Sleep -Milliseconds 10;$ready=[BoundedReadinessTest]::Poll([IntPtr]1000)}
 if(!$ready-or [BoundedReadinessTest]::Peak-ne 1){throw 'Current host did not recover with a single outstanding worker'}
 Write-Output 'PASS: 1000 host changes retain one blocked task, reject stale readiness, and recover after provider release'
}finally{[BoundedReadinessTest]::Release()}
