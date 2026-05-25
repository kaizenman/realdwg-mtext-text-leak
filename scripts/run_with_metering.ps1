# Launch helloworld.exe and sample Private Bytes / Working Set every 200 ms.
# Writes a time series CSV alongside captured stdout for offline inspection.
#
# Usage:
#   .\run_with_metering.ps1 -ExePath C:\path\to\helloworld.exe `
#                           -RegKey  "SOFTWARE\<vendor>\...\RealDWG" `
#                           -Iterations 30 `
#                           -Tag baseline `
#                           [-Dwg C:\path\to\input.dwg] `
#                           [-OutDir .]

param(
    [Parameter(Mandatory=$true)][string]$ExePath,
    [Parameter(Mandatory=$true)][string]$RegKey,
    [int]$Iterations = 30,
    [string]$Tag = "run",
    [string]$Dwg = "",
    [string]$OutDir = "."
)

if (-not (Test-Path $ExePath)) { throw "Not found: $ExePath" }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$stdout = Join-Path $OutDir "run_${Tag}.stdout.txt"
$stdin  = Join-Path $OutDir "run_${Tag}.stdin.txt"
$csv    = Join-Path $OutDir "run_${Tag}.csv"
Set-Content -Path $stdin -Value "" -Encoding ascii

$argList = @("`"$RegKey`"", "$Iterations")
if ($Dwg) { $argList += "`"$Dwg`"" }

$proc = Start-Process -FilePath $ExePath -ArgumentList $argList `
    -WorkingDirectory (Split-Path $ExePath) `
    -RedirectStandardOutput $stdout -RedirectStandardInput $stdin `
    -NoNewWindow -PassThru

$samples = New-Object System.Collections.Generic.List[object]
$sw = [System.Diagnostics.Stopwatch]::StartNew()

while (-not $proc.HasExited) {
    Start-Sleep -Milliseconds 200
    try { $proc.Refresh() } catch {}
    try {
        $pb = $proc.PrivateMemorySize64
        $ws = $proc.WorkingSet64
        $samples.Add([pscustomobject]@{
            t_ms       = [int]$sw.ElapsedMilliseconds
            private_mb = [math]::Round($pb/1MB, 1)
            working_mb = [math]::Round($ws/1MB, 1)
        })
    } catch {}
    if ($sw.Elapsed.TotalMinutes -gt 30) { try { $proc.Kill() } catch {}; break }
}

$proc.WaitForExit() | Out-Null
$samples | Export-Csv -NoTypeInformation -Path $csv

if ($samples.Count -gt 0) {
    $valid = $samples | Where-Object { $_.private_mb -gt 0 }
    $first = $valid[0]
    $peak  = ($valid | Measure-Object -Property private_mb -Maximum).Maximum
    $last  = $valid[$valid.Count - 1]
}

Write-Host ""
Write-Host "=== [$Tag] ==="
Write-Host "Iterations:        $Iterations"
Write-Host "Exit code:         $($proc.ExitCode)"
Write-Host "Wall time s:       $([math]::Round($sw.Elapsed.TotalSeconds,1))"
Write-Host "First Private MB:  $($first.private_mb)"
Write-Host "Peak  Private MB:  $peak"
Write-Host "Last  Private MB:  $($last.private_mb)"
Write-Host "CSV:               $csv"
Write-Host "Stdout:            $stdout"
