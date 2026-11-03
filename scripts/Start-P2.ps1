[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Apply','Restore')][string]$Mode,
      [string]$Config, [string]$Reports, [string]$Python, [string]$GpuJson,
      [string]$Plan, [string]$Confirm)
$ErrorActionPreference = 'Stop'
try {
    & (Join-Path $PSScriptRoot 'Set-GspMode.ps1') @PSBoundParameters
    $code = $LASTEXITCODE
    if ($code -eq 0) { Write-Host 'Operation verified. Restart Windows, then run Run-P2-Verify.cmd. The kit never restarts automatically.' }
    else { Write-Host 'Operation failed. Review the retained backup and receipt before proceeding.' }
    exit $code
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
