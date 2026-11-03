# All OS boundaries are mocks. No GPU, event log, registry or external executable is queried.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\P2-ReadOnly.ps1')
$results = @{}
$real = [pscustomobject]@{nvidia_smi=@{subject='CN=Microsoft Windows Hardware Compatibility Publisher, O=Microsoft Corporation'};
    pnp=@{instance_id='PCI\VEN_10DE&DEV_1E04&SUBSYS_ABCD1234&REV_A1\SYNTHETIC';driver_property='{4d36e968-e325-11ce-bfc1-08002be10318}\0000'}}
$mockWindows = Join-Path $env:SystemDrive 'SyntheticWindows'
$script:scenario = ''
$script:paths = @()
$script:oldestCalls = 0
$script:clearCalls = 0
function Test-Path {
    param($LiteralPath, $PathType)
    if ($LiteralPath -eq (Join-Path $mockWindows 'System32\nvidia-smi.exe')) { return $script:scenario -notin @('fallback','fallback-whql','bad-path','missing') }
    return $script:scenario -in @('fallback','fallback-whql','bad-path')
}
function Get-ChildItem {
    param($LiteralPath, [switch]$Directory, $Filter)
    if ($Filter -ne 'nv_dispi.inf_*' -or -not $Directory) { throw 'Unexpected search scope' }
    if ($script:scenario -in @('fallback','fallback-whql')) { [pscustomobject]@{FullName=(Join-Path $mockWindows 'System32\DriverStore\FileRepository\nv_dispi.inf_fixture')} }
    if ($script:scenario -eq 'bad-path') { [pscustomobject]@{FullName=(Join-Path $mockWindows 'System32\DriverStore\FileRepository\other.inf_fixture')} }
}
function Get-AuthenticodeSignature {
    param($LiteralPath)
    $script:paths += $LiteralPath
    if ($script:scenario -eq 'signature-error') { throw 'Signature unavailable' }
    $subject = 'CN=NVIDIA Corporation, O=NVIDIA Corporation, C=US'
    if ($script:scenario -eq 'foreign') { $subject = 'CN=NVIDIA Corporation, O=Other, C=US' }
    if ($script:scenario -in @('whql','fallback-whql','whql-invalid')) { $subject = $real.nvidia_smi.subject }
    if ($script:scenario -eq 'microsoft-other') { $subject = 'CN=Microsoft Windows, O=Microsoft Corporation, C=US' }
    if ($script:scenario -eq 'whql-foreign-org') { $subject = 'CN=Microsoft Windows Hardware Compatibility Publisher, O=Other, C=US' }
    $status = 'Valid'
    if ($script:scenario -in @('invalid','whql-invalid')) { $status = 'HashMismatch' }
    [pscustomobject]@{Status=$status;SignerCertificate=[pscustomobject]@{Subject=$subject;Thumbprint='fixture-cert'}}
}
foreach ($case in @('system32','fallback','missing','foreign','invalid','signature-error','whql','fallback-whql','whql-invalid','microsoft-other','whql-foreign-org','bad-path')) {
    $script:scenario = $case
    $script:paths = @()
    $value = Resolve-P2NvidiaSmi -WindowsRoot $mockWindows
    $results[$case] = @{value=$value; paths=$script:paths}
}
function Get-WinEvent {
    [CmdletBinding()]
    param($FilterHashtable, $LogName, [switch]$Oldest, $MaxEvents)
    if ($Oldest) {
        $script:oldestCalls++
        $time = [DateTime]'2026-10-30T00:00:00Z'
        if ($script:scenario -eq 'truncated' -or ($script:scenario -eq 'rollover' -and $script:oldestCalls -gt 1)) { $time = [DateTime]'2026-10-31T02:00:00Z' }
        if ($script:scenario -eq 'oldest-error') { throw 'Oldest unavailable' }
        return [pscustomobject]@{TimeCreated=$time}
    }
    if ($FilterHashtable.Id -eq 104) {
        $script:clearCalls++
        if ($script:scenario -eq 'cleared' -or ($script:scenario -eq 'clear-during' -and $script:clearCalls -gt 1)) { return [pscustomobject]@{Id=104} }
        return
    }
    if ($script:scenario -eq 'query-error') { throw 'Query denied' }
    if ($script:scenario -eq 'no-events') {
        $record = New-Object Management.Automation.ErrorRecord ([Exception]'No events'), 'NoMatchingEventsFound', ([Management.Automation.ErrorCategory]::ObjectNotFound), $null
        $PSCmdlet.ThrowTerminatingError($record)
    }
    if ($script:scenario -eq 'tdr' -and $FilterHashtable.Id -eq 4101) { return [pscustomobject]@{Id=4101} }
}
foreach ($case in @('covered','no-events','truncated','cleared','rollover','clear-during','oldest-error','query-error','tdr')) {
    $script:scenario = $case
    $script:oldestCalls = 0
    $script:clearCalls = 0
    $results[$case] = Get-P2SystemLogEvidence -Boot ([DateTime]'2026-10-31T01:00:00Z')
}
function Get-PnpDevice {
    param($Class, [switch]$PresentOnly)
    if ($Class -ne 'Display' -or -not $PresentOnly) { throw 'PresentOnly required' }
    if ($script:scenario -eq 'pnp-absent') { return }
    [pscustomobject]@{InstanceId=$real.pnp.instance_id}
    [pscustomobject]@{InstanceId='VMBUS\foreign\instance'}
}
function Get-PnpDeviceProperty {
    param($InstanceId, $KeyName)
    if ($KeyName -ne 'DEVPKEY_Device_Driver') { throw 'Wrong property' }
    if ($script:scenario -eq 'pnp-missing-property') { return [pscustomobject]@{Data=$null} }
    [pscustomobject]@{Data=$real.pnp.driver_property}
}
foreach ($case in @('pnp-present','pnp-absent','pnp-missing-property')) {
    $script:scenario = $case
    try { $results[$case] = @{devices=@(Get-P2PresentDisplay); failed=$false} }
    catch { $results[$case] = @{failed=$true} }
}
$results | ConvertTo-Json -Depth 16 -Compress
