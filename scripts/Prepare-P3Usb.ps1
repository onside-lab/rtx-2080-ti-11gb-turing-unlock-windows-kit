[CmdletBinding()]
param([string]$Config, [string]$Reports, [string]$GpuJson, [string]$UsbPolicy,
      [string]$MediaPolicy, [string]$Payload, [string]$InspectReport,
      [string]$InspectSha256, [string]$Confirm)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Kit-Common.ps1')
. (Join-Path $PSScriptRoot 'P3-Common.ps1')
$receiptPath = $null
$receipt = [ordered]@{schema_version=1; created_at_utc=[DateTime]::UtcNow.ToString('o'); status='refused'; reason=$null;
    write_attempted=$false; target=$null; steps=(New-Object 'System.Collections.Generic.List[object]');
    partial_files_must_not_be_booted=$true; automatic_cleanup=$false}
$code = 2
try {
    $environment = Read-KitEnvironment $Config ($PSBoundParameters.ContainsKey('Config'))
    $gpu = Resolve-KitGpu $environment $GpuJson ($PSBoundParameters.ContainsKey('GpuJson'))
    if ($gpu.bdf -notmatch '^[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$') { throw 'explicit-gpu-bdf-required' }
    $reportsPath = Resolve-KitPath (Resolve-KitSetting $environment 'reports_dir' $Reports ($PSBoundParameters.ContainsKey('Reports')) 'reports')
    $policy = Read-P3Json (Resolve-KitPath (Resolve-KitSetting $environment 'usb_policy' $UsbPolicy ($PSBoundParameters.ContainsKey('UsbPolicy'))))
    $media = Read-P3Json (Resolve-KitPath (Resolve-KitSetting $environment 'media_policy' $MediaPolicy ($PSBoundParameters.ContainsKey('MediaPolicy'))))
    $source = Resolve-KitPath (Resolve-KitSetting $environment 'payload_root' $Payload ($PSBoundParameters.ContainsKey('Payload')))
    $inspectPath = Resolve-KitPath (Resolve-KitSetting $policy 'inspect_report' $InspectReport ($PSBoundParameters.ContainsKey('InspectReport')))
    $inspectHash = Resolve-KitSetting $policy 'inspect_sha256' $InspectSha256 ($PSBoundParameters.ContainsKey('InspectSha256'))
    if ($inspectHash -notmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $inspectPath -Algorithm SHA256).Hash -ine $inspectHash) { throw 'inspect-report-hash-mismatch' }
    $inspect = Read-P3Json $inspectPath
    if (-not (Test-P3Admin)) { throw 'administrator-required-open-an-elevated-terminal' }
    $files = @(Get-P3Payload $source $policy)
    if ([IO.File]::ReadAllText((Get-P3PayloadPaths $source 'tx-select-bdf.txt').target).Trim() -ine $gpu.bdf) { throw 'payload-gpu-bdf-mismatch' }
    $volume = Resolve-P3Pinned (Get-P3Inventory (Get-KitRoot)) $inspect $policy $media (Get-KitRoot)
    Assert-P3Empty $volume
    Write-Host ('Volume GUID: ' + $volume.path)
    Write-Host ('Identity: ' + $policy.identity_sha256 + '; binding: ' + $policy.binding_sha256)
    Write-Host ('Payload folder: ' + $source)
    Write-Host 'The upstream EFI requires Space/Enter confirmation and aborts after 30 seconds without input.'
    Assert-KitConfirmation ('COPY USB ' + $policy.identity_sha256) $Confirm ($PSBoundParameters.ContainsKey('Confirm'))
    $files = @(Get-P3Payload $source $policy)
    # Reinventory after the human prompt, immediately before the first USB mutation.
    $volume = Resolve-P3Pinned (Get-P3Inventory (Get-KitRoot)) $inspect $policy $media (Get-KitRoot)
    Assert-P3Empty $volume
    $required = 16777216L + 4L * $volume.allocation_unit_bytes
    foreach ($entry in $files) { $required += [long]([Math]::Ceiling($entry.bytes / [double]$volume.allocation_unit_bytes) * $volume.allocation_unit_bytes) }
    if ($volume.free_bytes -lt $required) { throw 'insufficient-free-space-including-log-reserve' }
    [IO.Directory]::CreateDirectory($reportsPath) | Out-Null
    $receiptPath = Join-Path $reportsPath ('p3-usb-write-' + (Get-P3Stamp) + '.json')
    $receipt.target = @{identity_sha256=$policy.identity_sha256; binding_sha256=$policy.binding_sha256; volume_guid_path=$volume.path; required_bytes=$required; free_bytes=$volume.free_bytes}
    $receipt['payload_files'] = $files
    $receipt['inspect_report'] = $inspectPath
    $receipt['inspect_sha256'] = $inspectHash
    $receipt['gpu'] = $gpu
    $receipt.write_attempted = $true
    Copy-P3Payload $source $volume.path $files $receipt
    $receipt.status = 'copy-verified'
    $receipt.partial_files_must_not_be_booted = $false
    $code = 0
} catch {
    $receipt.reason = $_.Exception.Message
    if ($receipt.write_attempted) { $receipt.status = 'partial-failure' }
    [Console]::Error.WriteLine($receipt.reason)
    $code = 1
}
if ($null -ne $receiptPath) {
    try { Write-P3Json $receiptPath $receipt; Write-Host $receiptPath }
    catch { [Console]::Error.WriteLine($_.Exception.Message); $code = 2 }
}
exit $code
