using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

// The parent exits successfully, but its child owns copies of both redirected
// handles. Process.WaitForExit(timeout) alone cannot bound ReadToEndAsync.
public static class InheritedCliPipes {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct Startup {
    public int cb; public string reserved,desktop,title;
    public int x,y,xSize,ySize,xChars,yChars,fill,flags;
    public short show,reservedSize;
    public IntPtr reservedData,input,output,error;
  }
  [StructLayout(LayoutKind.Sequential)]
  struct ProcessInfo {public IntPtr process,thread;public int pid,tid;}
  [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int which);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetHandleInformation(IntPtr h,uint mask,uint flags);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern bool CreateProcess(string app,StringBuilder command,IntPtr security,IntPtr threadSecurity,bool inherit,int flags,IntPtr environment,string directory,ref Startup startup,out ProcessInfo info);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  public static int Main(string[] args) {
    if(args[0]=="child") {
      Console.WriteLine("child stdout");Console.Error.WriteLine("child stderr");
      Thread.Sleep(3500);return 0;
    }
    var start=new Startup();start.cb=Marshal.SizeOf(start);start.flags=0x100;
    start.input=GetStdHandle(-10);start.output=GetStdHandle(-11);start.error=GetStdHandle(-12);
    if(!SetHandleInformation(start.output,1,1)||!SetHandleInformation(start.error,1,1))return 2;
    string exe=System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName;
    ProcessInfo child;
    if(!CreateProcess(exe,new StringBuilder("\""+exe+"\" child"),IntPtr.Zero,IntPtr.Zero,true,0x08000000,IntPtr.Zero,null,ref start,out child))return 3;
    File.WriteAllText(args[0],child.pid.ToString());
    CloseHandle(child.process);CloseHandle(child.thread);
    return 0;
  }
}
