[CmdletBinding()]
param([string]$Config, [string]$Reports, [string]$Python, [string]$GpuJson,
      [string]$UsbPolicy, [string]$MediaPolicy, [string]$InspectReport, [string]$InspectSha256)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Kit-Common.ps1')
try {
$environment = Read-KitEnvironment $Config ($PSBoundParameters.ContainsKey('Config'))
$gpu = Resolve-KitGpu $environment $GpuJson ($PSBoundParameters.ContainsKey('GpuJson'))
$reports = Resolve-KitPath (Resolve-KitSetting $environment 'reports_dir' $Reports ($PSBoundParameters.ContainsKey('Reports')) 'reports')
$pythonExe = Resolve-KitSetting $environment 'python_executable' $Python ($PSBoundParameters.ContainsKey('Python')) 'python.exe'
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 2 }

$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
. (Join-Path $PSScriptRoot 'P3-Common.ps1')
. (Join-Path $PSScriptRoot 'P2-ReadOnly.ps1')
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$folder = Join-Path $reports ('p3-return-' + (Get-P3Stamp))
[IO.Directory]::CreateDirectory($folder) | Out-Null
$issues = New-Object 'System.Collections.Generic.List[string]'
$data = [ordered]@{schema_version=1; gpu=$gpu; read_only=$true; collected_at_utc=[DateTime]::UtcNow.ToString('o');
    last_boot_utc=$null; secure_boot='unknown'; secure_boot_error=$null; loader_log=$null;
    nvidia_smi_executable=$null; nvidia_smi_q=$null; nvidia_smi_exit_code=$null; pnp_devices=$null;
    system_log=$null; media_hashes_verified=$false; collection_errors=@()}
$boot = $null
try {
    $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    if ($null -eq $boot) { throw 'LastBootUpTime unavailable' }
    $data.last_boot_utc = $boot.ToUniversalTime().ToString('o')
} catch { $issues.Add('last-boot: ' + $_.Exception.Message) }
if (Test-P3Admin) {
    try { $data.secure_boot = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) }
    catch { $data.secure_boot_error = $_.Exception.Message }
} else { $data.secure_boot_error = 'administrator-required-for-confirm-securebootuefi' }
try {
    $policy = Read-P3Json (Resolve-KitPath (Resolve-KitSetting $environment 'usb_policy' $UsbPolicy ($PSBoundParameters.ContainsKey('UsbPolicy'))))
    Assert-P3Manifest $policy
    $inspectPath = Resolve-KitPath (Resolve-KitSetting $policy 'inspect_report' $InspectReport ($PSBoundParameters.ContainsKey('InspectReport')))
    $inspectHash = Resolve-KitSetting $policy 'inspect_sha256' $InspectSha256 ($PSBoundParameters.ContainsKey('InspectSha256'))
    if ($inspectHash -notmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $inspectPath -Algorithm SHA256).Hash -ine $inspectHash) { throw 'inspect-report-hash-mismatch' }
    $volume = Resolve-P3Pinned (Get-P3Inventory $root) (Read-P3Json $inspectPath) $policy (Read-P3Json (Resolve-KitPath (Resolve-KitSetting $environment 'media_policy' $MediaPolicy ($PSBoundParameters.ContainsKey('MediaPolicy'))))) $root
    $receipts = @(Get-ChildItem -LiteralPath $reports -Filter 'p3-usb-write-*.json' -File -ErrorAction Stop | ForEach-Object {
        $r = Read-P3Json $_.FullName
        if ($r.status -eq 'copy-verified' -and $r.target.identity_sha256 -eq $policy.identity_sha256 -and $r.target.binding_sha256 -eq $policy.binding_sha256 -and
            $r.target.volume_guid_path -ceq $policy.volume_guid_path -and $r.gpu.uuid -ieq $gpu.uuid -and $r.gpu.pnp_instance_id -ieq $gpu.pnp_instance_id) {
            Assert-P3Manifest $r
            foreach ($entry in $policy.payload_files) {
                $matches = @($r.payload_files | Where-Object { $_.path -ceq $entry.path -and $_.sha256 -ceq $entry.sha256 -and $_.bytes -eq $entry.bytes })
                if ($matches.Count -ne 1) { throw 'copy-receipt-payload-manifest-mismatch' }
            }
            @{path=$_.FullName; data=$r}
        }
    } | Sort-Object { $_.data.created_at_utc } -Descending)
    if ($receipts.Count -eq 0) { throw 'matching-copy-verified-receipt-required' }
    $receipt = $receipts[0]
    $prepared = [DateTime]::Parse($receipt.data.created_at_utc).ToUniversalTime()
    $log = (Get-P3PayloadPaths $volume.path 'loader.log').target
    Assert-P3NoReparse $log
    $info = Get-Item -LiteralPath $log -Force -ErrorAction Stop
    if ($info.PSIsContainer -or $info.Length -gt 16777216 -or $info.Length -eq 0) { throw 'loader-log-size-invalid' }
    $before = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash.ToLowerInvariant()
    $copy = Join-Path $folder 'loader.log'
    Copy-P3CreateNew $log $copy
    $after = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash.ToLowerInvariant()
    $copied = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash.ToLowerInvariant()
    $data.loader_log = @{source=$log; copy=$copy; source_sha256_before=$before; source_sha256_after=$after; copy_sha256=$copied;
        hash_verified=($before -eq $after -and $before -eq $copied); last_write_utc=$info.LastWriteTimeUtc.ToString('o');
        media_write_receipt=$receipt.path; media_prepared_at_utc=$prepared.ToString('o');
        fresh_from_prepared_media=($null -ne $boot -and $boot.ToUniversalTime() -ge $prepared -and
            $info.LastWriteTimeUtc -ge $prepared.AddSeconds(-2) -and $info.LastWriteTimeUtc -le [DateTime]::UtcNow.AddSeconds(2));
        log_seconds_before_windows_boot=$(if ($null -ne $boot) { ($boot.ToUniversalTime() - $info.LastWriteTimeUtc).TotalSeconds } else { $null });
        current_boot_correlation_established=$false}
    if (-not $data.loader_log.hash_verified) { throw 'loader-log-copy-hash-mismatch' }
    foreach ($entry in $policy.payload_files) {
        $path = (Get-P3PayloadPaths $volume.path $entry.path).target
        Assert-P3NoReparse $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.sha256 -or (Get-Item -LiteralPath $path).Length -ne $entry.bytes) { throw ('media-hash-mismatch: ' + $entry.path) }
    }
    $data.media_hashes_verified = $true
} catch { $issues.Add('usb-log: ' + $_.Exception.Message) }
try {
    $smi = Get-P2TargetSmi $gpu
    $data.nvidia_smi_executable = $smi.executable
    $data.nvidia_smi_target = $smi.target
    $rows = @(& $data.nvidia_smi_executable.path '-q' '-i' $gpu.uuid 2>&1)
    $data.nvidia_smi_exit_code = $LASTEXITCODE
    $data.nvidia_smi_q = ($rows | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ($data.nvidia_smi_exit_code -ne 0) { throw 'nvidia-smi -q failed' }
} catch { $issues.Add('nvidia-smi: ' + $_.Exception.Message) }
try {
    $devices = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop | Where-Object { $_.InstanceId -match '^PCI\\VEN_10DE&' })
    if ($devices.Count -ne 1 -or $devices[0].InstanceId -ine $gpu.pnp_instance_id) { throw 'Exactly one matching NVIDIA display required' }
    $data.pnp_devices = @($devices | ForEach-Object {
        $problem = Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction Stop
        if ($null -eq $problem.Data) { throw 'Missing ProblemCode' }
        @{instance_id=$_.InstanceId; status=[string]$_.Status; problem_code=[int]$problem.Data; code_43=([int]$problem.Data -eq 43)}
    })
} catch { $issues.Add('pnp: ' + $_.Exception.Message) }
if ($null -ne $boot) {
    try {
        $data.system_log = Get-P2SystemLogEvidence -Boot $boot
        if (-not $data.system_log.complete) { $issues.Add('system-log: ' + $data.system_log.error) }
    } catch { $issues.Add('system-log: ' + $_.Exception.Message) }
}
$data.collection_errors = @($issues.ToArray())
$inputPath = Join-Path $folder 'collection.json'
$reportPath = Join-Path $folder 'result.json'
$code = 2
try {
    Write-P3Json $inputPath $data
    $out = @(& $pythonExe -X utf8 (Join-Path $root 'scripts/p3_return.py') --input $inputPath --report $reportPath 2>&1)
    $code = $LASTEXITCODE
    if ($code -notin @(0,1,2) -or -not [IO.File]::Exists($reportPath)) { throw 'Collector produced no valid result' }
    $result = Read-P3Json $reportPath
    $expectedStatus = @{0='collected-candidate';1='collected-needs-review';2='tool-failed'}[$code]
    if ($result.exit_code -ne $code -or $result.status -ne $expectedStatus) { throw 'Collector result/exit mismatch' }
} catch {
    $code = 2
    try { Write-P3Json (Join-Path $folder 'tool-error.json') @{error=$_.Exception.Message; output=@($out); snapshot=$data; exit_code=2} }
    catch { [Console]::Error.WriteLine($_.Exception.Message) }
}
Write-Host $folder
if ($code -eq 0) { Write-Host 'Collection complete; candidate evidence only. Numerical validation remains required.' }
elseif ($code -eq 1) { Write-Host 'Collection complete; review unmet criteria in the report.' }
else { Write-Host 'Collection failed; review the retained evidence.' }
exit $code
