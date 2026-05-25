# Snapshot a running process's committed memory regions via VirtualQueryEx.
# Aggregates by AllocationBase to expose private (non-Heap) pool segments.
#
# Usage:
#   .\dump_regions.ps1 -ProcId <pid> -Tag baseline [-OutDir .]

param(
    [Parameter(Mandatory=$true)][int]$ProcId,
    [string]$Tag = "snap",
    [string]$OutDir = "."
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Mem {
    [DllImport("kernel32")] public static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("psapi.dll")] public static extern uint GetMappedFileNameW(IntPtr h, IntPtr addr, System.Text.StringBuilder buf, uint size);
    [StructLayout(LayoutKind.Sequential)]
    public struct MBI {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint   AllocationProtect;
        public ushort PartitionId;
        public ushort _pad;
        public IntPtr RegionSize;
        public uint   State;
        public uint   Protect;
        public uint   Type;
    }
    [DllImport("kernel32")] public static extern IntPtr VirtualQueryEx(IntPtr h, IntPtr addr, ref MBI buf, IntPtr len);
}
"@

# PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
$h = [Mem]::OpenProcess(0x1010, $false, $ProcId)
if ($h -eq [IntPtr]::Zero) { throw "OpenProcess failed (pid=$ProcId)" }

$mbiSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'Mem+MBI')
$addr = [IntPtr]::Zero
$end  = [IntPtr]::new(0x7FFFFFFEFFFF)

$rows = New-Object System.Collections.Generic.List[object]
$mbi  = New-Object 'Mem+MBI'

while ($addr.ToInt64() -lt $end.ToInt64()) {
    $r = [Mem]::VirtualQueryEx($h, $addr, [ref]$mbi, [IntPtr]::new($mbiSize))
    if ($r -eq [IntPtr]::Zero) { break }
    $regionSize = $mbi.RegionSize.ToInt64()
    if ($regionSize -eq 0) { break }
    if ($mbi.State -eq 0x1000) {  # MEM_COMMIT
        $type = switch ($mbi.Type) { 0x20000 {"Private"} 0x40000 {"Mapped"} 0x1000000 {"Image"} default {"?"} }
        $name = ""
        if ($mbi.Type -eq 0x40000 -or $mbi.Type -eq 0x1000000) {
            $sb = New-Object System.Text.StringBuilder 512
            $nb = [Mem]::GetMappedFileNameW($h, $mbi.BaseAddress, $sb, 512)
            if ($nb -gt 0) { $name = $sb.ToString() }
        }
        $rows.Add([pscustomobject]@{
            BaseAddr  = '0x{0:X12}' -f $mbi.BaseAddress.ToInt64()
            AllocBase = '0x{0:X12}' -f $mbi.AllocationBase.ToInt64()
            SizeKB    = [math]::Round($regionSize / 1KB, 1)
            Type      = $type
            Protect   = '0x{0:X}' -f $mbi.Protect
            Name      = $name
        })
    }
    $addr = [IntPtr]::new($addr.ToInt64() + $regionSize)
}
[Mem]::CloseHandle($h) | Out-Null

$agg = $rows | Group-Object -Property AllocBase | ForEach-Object {
    $first = $_.Group[0]
    [pscustomobject]@{
        AllocBase = $first.AllocBase
        TotalMB   = [math]::Round((($_.Group | Measure-Object -Property SizeKB -Sum).Sum)/1024, 2)
        Regions   = $_.Count
        Type      = ($_.Group | Group-Object Type | Sort-Object -Property Count -Descending | Select-Object -First 1).Name
        Name      = ($_.Group | Where-Object { $_.Name -ne "" } | Select-Object -First 1).Name
    }
}

$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$csv = Join-Path $OutDir "regions_$Tag.csv"
$agg | Sort-Object -Property TotalMB -Descending | Export-Csv -NoTypeInformation -Path $csv

$totals = $rows | Group-Object -Property Type | ForEach-Object {
    [pscustomobject]@{
        Type    = $_.Name
        TotalMB = [math]::Round((($_.Group | Measure-Object -Property SizeKB -Sum).Sum)/1024, 1)
        Count   = $_.Count
    }
}

Write-Host "=== Snap [$Tag] PID=$ProcId ==="
Write-Host "Total committed regions: $($rows.Count)"
$totals | Sort-Object -Property TotalMB -Descending | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Top 15 allocation bases by size:"
$agg | Sort-Object -Property TotalMB -Descending | Select-Object -First 15 | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "CSV: $csv"
