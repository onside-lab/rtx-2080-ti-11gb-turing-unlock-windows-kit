# Native entrypoint integration with simulated hardware and synthetic payloads.
param([string]$FixtureRoot,[ValidateSet('Inspect','Prepare','Collect')][string]$Entry,[string]$Scenario='Good')
$ErrorActionPreference = 'Stop'
function Get-Disk { throw 'Live disk access prohibited' }
function Get-Partition { throw 'Live partition access prohibited' }
function Get-Volume { throw 'Live volume access prohibited' }
function Start-Process { throw 'Elevation prohibited' }
function Confirm-SecureBootUEFI { throw 'Live Secure Boot access prohibited' }
function Set-ItemProperty { throw 'Registry writes prohibited' }
function Get-CimInstance { [pscustomobject]@{LastBootUpTime=[DateTime]::UtcNow} }
function Get-PnpDevice { [pscustomobject]@{InstanceId='PCI\VEN_10DE&DEV_1E04&SUBSYS_ABCD1234&REV_A1\4&abc';Status=$(if ($Scenario -eq 'Unmet') { 'Error' } else { 'OK' })} }
function Get-PnpDeviceProperty { [pscustomobject]@{Data=$(if ($Scenario -eq 'Unmet') { 43 } else { 0 })} }
$mock=@'
$originalCopy=${function:Copy-P3Payload}
function Test-P3Admin { $Entry -eq 'Prepare' }
function Get-P3Inventory {
    if ($Scenario -eq 'OversizedManifest') { throw 'inventory-must-not-be-reached' }
    @{errors=@();disks=@()}
}
function Get-P3Selection { [pscustomobject]@{status='identified';reason=$null;candidates=@(@{identity_sha256=('a'*64)});excluded=@();candidate_count=1} }
function Get-P3Binding { 'b'*64 }
function Resolve-P3Pinned {
    $script:inventoryChecks++
    if ($Scenario -eq 'Swap' -and $script:inventoryChecks -ge 2) { throw 'live-identity-mismatch' }
    [pscustomobject]@{path=(Join-Path $FixtureRoot 'usb');file_system='FAT32';free_bytes=$(if ($Scenario -eq 'NoSpace') { 1 } else { 7900000000L });allocation_unit_bytes=4096;root_listing_error=$null;root_entries=@()}
}
function Copy-P3Payload {
    param($Source,$Destination,$Files,$Receipt)
    if ($Scenario -eq 'CopyFailure') { $Receipt.steps.Add(@{path='synthetic';status='copy-attempted'}); throw 'injected copy failure' }
    & $originalCopy $Source $Destination $Files $Receipt
}
'@
$common=Join-Path $FixtureRoot 'scripts/P3-Common.ps1'
[IO.File]::AppendAllText($common,$mock)
$helper=@'
function Resolve-P2NvidiaSmi { @{trusted=$true;path=(Join-Path $FixtureRoot 'smi.ps1');signature=@{status='Valid';subject='O=NVIDIA Corporation'}} }
function Get-P2TargetSmi { @{executable=(Resolve-P2NvidiaSmi);target=@{uuid='GPU-abcd';pci_device_id='0x1e0410de';pci_sub_device_id='0xabcd1234'}} }
function Get-P2SystemLogEvidence { @{complete=$true;display_4101_count=0;nvlddmkm_error_count=0} }
'@
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'scripts/P2-ReadOnly.ps1'),$helper)
$smi=@'
$data.nvidia_smi_executable.path=Join-Path $env:SystemRoot 'System32/nvidia-smi.exe'
'Driver Version : 610.88 [Deprecated; will be removed in CUDA 14.0. Use KMD Version instead]'
'GSP Firmware Version : 610.57.01'
$global:LASTEXITCODE=0
'@
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'smi.ps1'),$smi)
function Invoke-FixturePython { & $env:KIT_TEST_PYTHON @args; $global:LASTEXITCODE=$LASTEXITCODE }
if ($Scenario -eq 'LaunchFailure') { function Invoke-FixturePython { throw 'injected launch failure' } }
if ($Scenario -eq 'MissingReport') { function Invoke-FixturePython { $global:LASTEXITCODE=1 } }
if ($Scenario -eq 'Bom') {
    $bom=@'
$originalJsonWriter=${function:Write-P3Json}
function Write-P3Json {
    param($Path,$Data)
    if ((Split-Path -Leaf $Path) -eq 'collection.json') { [IO.File]::WriteAllText($Path,($Data | ConvertTo-Json -Depth 40),(New-Object Text.UTF8Encoding($true))) }
    else { & $originalJsonWriter $Path $Data }
}
'@
    [IO.File]::AppendAllText($common,$bom)
}
$config=Join-Path $FixtureRoot 'config/environment.local.json'
if ($Entry -eq 'Inspect') { & (Join-Path $FixtureRoot 'scripts/Inspect-P3Usb.ps1') -Config $config }
elseif ($Entry -eq 'Prepare') {
    $confirmation=if ($Scenario -eq 'BadConfirmation') { 'wrong' } else { 'COPY USB ' + ('a'*64) }
    & (Join-Path $FixtureRoot 'scripts/Prepare-P3Usb.ps1') -Config $config -Confirm $confirmation
} else { & (Join-Path $FixtureRoot 'scripts/Collect-P3Return.ps1') -Config $config -Python Invoke-FixturePython }
exit $LASTEXITCODE
