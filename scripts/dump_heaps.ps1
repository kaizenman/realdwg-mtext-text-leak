# Enumerate OS-registered heaps in a running process via Heap32List.
# Proves whether private memory growth happens through Win32 heaps (HeapCreate)
# or via direct VirtualAlloc (which Heap32List does not see).
#
# Usage:
#   .\dump_heaps.ps1 -ProcId <pid> -Tag baseline [-OutDir .]

param(
    [Parameter(Mandatory=$true)][int]$ProcId,
    [string]$Tag = "heaps",
    [string]$OutDir = "."
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class HeapEnum {
    public const uint TH32CS_SNAPHEAPLIST = 0x00000001;

    [StructLayout(LayoutKind.Sequential)]
    public struct HEAPLIST32 {
        public IntPtr dwSize;
        public uint   th32ProcessID;
        public IntPtr th32HeapID;
        public uint   dwFlags;
    }
    [DllImport("kernel32")] public static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32")] public static extern bool   Heap32ListFirst(IntPtr snap, ref HEAPLIST32 hl);
    [DllImport("kernel32")] public static extern bool   Heap32ListNext (IntPtr snap, ref HEAPLIST32 hl);
    [DllImport("kernel32")] public static extern bool   CloseHandle(IntPtr h);
}
"@

$snap = [HeapEnum]::CreateToolhelp32Snapshot([HeapEnum]::TH32CS_SNAPHEAPLIST, [uint32]$ProcId)
if ($snap.ToInt64() -eq -1) { throw "Toolhelp snapshot failed" }

$hl = New-Object 'HeapEnum+HEAPLIST32'
$hl.dwSize = [IntPtr]::new([System.Runtime.InteropServices.Marshal]::SizeOf($hl))
$heaps = New-Object System.Collections.Generic.List[object]
$first = [HeapEnum]::Heap32ListFirst($snap, [ref]$hl)
if ($first) {
    do {
        $heaps.Add([pscustomobject]@{
            HeapID    = '0x{0:X12}' -f $hl.th32HeapID.ToInt64()
            Flags     = '0x{0:X}'   -f $hl.dwFlags
            IsDefault = ($hl.dwFlags -band 1) -ne 0
        })
    } while ([HeapEnum]::Heap32ListNext($snap, [ref]$hl))
}
[HeapEnum]::CloseHandle($snap) | Out-Null

Write-Host "=== Heaps [$Tag] PID=$ProcId ==="
Write-Host "Total heaps registered with the OS: $($heaps.Count)"
$heaps | Format-Table -AutoSize | Out-String | Write-Host

$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$csv = Join-Path $OutDir "heaps_$Tag.csv"
$heaps | Export-Csv -NoTypeInformation -Path $csv
Write-Host "CSV: $csv"
