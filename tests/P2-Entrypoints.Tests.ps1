# Copied production entrypoints with simulated OS boundaries only.
param([string]$FixtureRoot, [ValidateSet('Verify','Preflight','Apply','Restore')][string]$Entry,
      [string]$Scenario='Good')
$ErrorActionPreference = 'Stop'
function Get-Disk { throw 'Live disk access prohibited' }
function Get-Partition { throw 'Live disk access prohibited' }
function Get-Volume { throw 'Live disk access prohibited' }
function Get-CimInstance { [pscustomobject]@{LastBootUpTime=[DateTime]'2026-01-01T00:00:00Z'} }
function Get-PnpDevice { [pscustomobject]@{InstanceId='PCI\VEN_10DE&DEV_1E04&SUBSYS_ABCD1234&REV_A1\4&abc';Status='OK'} }
function Get-PnpDeviceProperty {
    param($InstanceId,$KeyName)
    if ($Scenario -eq 'CollectionFailure') { throw 'injected PnP failure' }
    [pscustomobject]@{Data=$(if ($KeyName -eq 'DEVPKEY_Device_Driver') { '{4d36e968-e325-11ce-bfc1-08002be10318}\0000' } else { 0 })}
}
function Get-ChildItem {
    param($LiteralPath,[switch]$Name)
    if ($LiteralPath -notlike 'Registry::*' -or -not $Name) { throw 'Unexpected registry access' }
    '0000'
}
function Get-Item {
    param($LiteralPath)
    if ($LiteralPath -notlike 'Registry::*') { throw 'Unexpected item access' }
    $key=[pscustomobject]@{Name='HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000'}
    $key | Add-Member ScriptMethod GetValue { param($Name,$Default); if ($Name -eq 'MatchingDeviceId') { 'pci\ven_10de&dev_1e04&subsys_abcd1234&rev_a1' } else { 1 } }
    $key | Add-Member ScriptMethod GetValueNames { @('MatchingDeviceId','EnableGpuFirmware') }
    $key | Add-Member ScriptMethod GetValueKind { 'DWord' }
    $key | Add-Member ScriptMethod Close { }
    $key
}
function Set-ItemProperty { throw 'Registry writes prohibited' }
function New-ItemProperty { throw 'Registry writes prohibited' }
function Remove-ItemProperty { throw 'Registry writes prohibited' }
function Start-Process { throw 'Process elevation prohibited' }
$helper=@'
function Resolve-P2NvidiaSmi { @{trusted=$true;path=(Join-Path $FixtureRoot 'smi.ps1');signature=@{status='Valid';subject='O=NVIDIA Corporation'}} }
function Get-P2SystemLogEvidence { @{complete=$true;display_4101_count=0;nvlddmkm_error_count=0} }
'@
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'scripts/P2-ReadOnly.ps1'),$helper)
$smi=@'
if ($args[0] -like '--query-gpu=*') { 'GPU-abcd, 0x1E0410DE, 0xABCD1234' }
else {
    $data.nvidia_smi_executable.path=Join-Path $env:SystemRoot 'System32/nvidia-smi.exe'
    'Driver Version : 610.88 [Deprecated; will be removed in CUDA 14.0. Use KMD Version instead]'
    if ($Scenario -eq 'Unmet') { 'GSP Firmware Version : N/A' } else { 'GSP Firmware Version : 610.57.01' }
}
$global:LASTEXITCODE=0
'@
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'smi.ps1'),$smi)
$config=Join-Path $FixtureRoot 'config/environment.local.json'
if ($Entry -in @('Apply','Restore')) {
    # Simulate elevation and capture the child boundary without executing p2.gsp.
    function New-Object {
        param([string]$TypeName,[object[]]$ArgumentList)
        if ($TypeName -eq 'Security.Principal.WindowsPrincipal') {
            $principal=[pscustomobject]@{}
            $principal | Add-Member ScriptMethod IsInRole { param($Role); $true }
            return $principal
        }
        Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
    }
    function Invoke-FixturePython {
        $forwarded=@($args)
        $inputPath=$forwarded[[Array]::IndexOf($forwarded,'--config')+1]
        $capture=@{arguments=$forwarded;input=(Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json);cwd=(Get-Location).Path}
        [IO.File]::WriteAllText((Join-Path $FixtureRoot 'reports/python-call.json'),($capture | ConvertTo-Json -Depth 10))
        $global:LASTEXITCODE=0
    }
    $confirmation=if ($Scenario -eq 'EmptyConfirmation') { '' }
                  elseif ($Scenario -eq 'BadConfirmation') { 'wrong' }
                  else { $(if ($Entry -eq 'Apply') { 'ENABLE GSP ' } else { 'RESTORE GSP ' }) + 'GPU-abcd' }
    $parameters=@{Mode=$Entry;Config=$config;Python='Invoke-FixturePython';Confirm=$confirmation}
    if ($Entry -eq 'Apply') { $parameters.Plan='reports/synthetic-plan.json' }
    & (Join-Path $FixtureRoot 'scripts/Set-GspMode.ps1') @parameters
} elseif ($Entry -eq 'Preflight') {
    function Invoke-FixturePython {
        & $env:KIT_TEST_PYTHON -X utf8 (Join-Path $PSScriptRoot 'entry_python.py') @args
        $global:LASTEXITCODE=$LASTEXITCODE
    }
    & (Join-Path $FixtureRoot 'scripts/Set-GspMode.ps1') -Preflight -Config $config -Python Invoke-FixturePython
} else {
    if ($Scenario -eq 'LaunchFailure') { function Invoke-FixturePython { throw 'injected launch failure' } }
    elseif ($Scenario -eq 'MissingReport') { function Invoke-FixturePython { $global:LASTEXITCODE=1 } }
    else {
        function Invoke-FixturePython { & $env:KIT_TEST_PYTHON @args; $global:LASTEXITCODE=$LASTEXITCODE }
    }
    if ($Scenario -eq 'Bom') {
        function ConvertTo-Json {
            param([Parameter(ValueFromPipeline=$true)]$InputObject,[int]$Depth)
            process { [string][char]0xFEFF + (Microsoft.PowerShell.Utility\ConvertTo-Json -InputObject $InputObject -Depth $Depth) }
        }
    }
    & (Join-Path $FixtureRoot 'scripts/Verify-P2.ps1') -Config $config -Python Invoke-FixturePython
}
exit $LASTEXITCODE
