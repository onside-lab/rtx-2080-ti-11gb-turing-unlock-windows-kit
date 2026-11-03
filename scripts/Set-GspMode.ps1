[CmdletBinding()]
param([ValidateSet('Apply','Restore')][string]$Mode, [switch]$Preflight,
      [string]$Config, [string]$Reports, [string]$Python, [string]$GpuJson,
      [string]$Plan, [string]$Confirm)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Kit-Common.ps1')
try {
    if (($Preflight -and $Mode) -or (-not $Preflight -and -not $Mode)) { throw 'Specify -Preflight or -Mode Apply/Restore.' }
    $environment = Read-KitEnvironment $Config ($PSBoundParameters.ContainsKey('Config'))
    $gpu = Resolve-KitGpu $environment $GpuJson ($PSBoundParameters.ContainsKey('GpuJson'))
    $pythonExe = Resolve-KitSetting $environment 'python_executable' $Python ($PSBoundParameters.ContainsKey('Python')) 'python.exe'
    $reportsPath = Resolve-KitPath (Resolve-KitSetting $environment 'reports_dir' $Reports ($PSBoundParameters.ContainsKey('Reports')) 'reports')
    $operation = if ($Preflight) { 'preflight' } else { $Mode.ToLowerInvariant() }
    $arguments = @('-X','utf8','-m','p2.gsp',$operation,'--reports',$reportsPath)
    if (-not $Preflight) {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges required. Open an elevated terminal.' }
        if ($Mode -eq 'Apply') {
            $planPath = Resolve-KitPath (Resolve-KitSetting $environment 'gsp_plan' $Plan ($PSBoundParameters.ContainsKey('Plan')))
            $arguments += @('--plan',$planPath)
        }
        $expected = $(if ($Mode -eq 'Apply') { 'ENABLE GSP ' } else { 'RESTORE GSP ' }) + $gpu.uuid
        Write-Host ('PnP target: ' + $gpu.pnp_instance_id)
        Assert-KitConfirmation $expected $Confirm ($PSBoundParameters.ContainsKey('Confirm'))
        $arguments += @('--confirm',$expected)
    }
    # PS 5.1 strips embedded quotes in native arguments. Use a BOM-free JSON file.
    [IO.Directory]::CreateDirectory($reportsPath) | Out-Null
    $inputPath = Join-Path $reportsPath ('.gsp-input-' + [Guid]::NewGuid().ToString('N') + '.local.json')
    $stream = [IO.File]::Open($inputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes((@{gpu=$gpu} | ConvertTo-Json -Depth 8))
        $stream.Write($bytes,0,$bytes.Length)
    } finally { $stream.Dispose() }
    $arguments += @('--config',$inputPath)
    Push-Location -LiteralPath (Get-KitRoot)
    try { & $pythonExe @arguments; $code = $LASTEXITCODE }
    finally { Pop-Location; [IO.File]::Delete($inputPath) }
    if ($null -eq $code) { throw 'Python returned no exit code' }
    exit $code
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
