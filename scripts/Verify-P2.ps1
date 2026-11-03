[CmdletBinding()]
param([string]$Config, [string]$Reports, [string]$Python, [string]$GpuJson,
      [string]$UsbPolicy, [string]$MediaPolicy)

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
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$issues = New-Object 'System.Collections.Generic.List[string]'
$data = [ordered]@{
    schema_version = 1
    gpu = $gpu
    observed_at_utc = [DateTime]::UtcNow.ToString('o')
    last_boot_utc = $null
    nvidia_smi_executable = $null
    system_log = $null
    nvidia_smi_target = $null
    nvidia_smi_q = $null
    nvidia_smi_exit_code = $null
    pnp_devices = $null
    display_4101_count_since_boot = $null
    nvlddmkm_error_count_since_boot = $null
    gsp_registry = $null
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '-' + [Guid]::NewGuid().ToString('N')
$reportPath = Join-Path $reports ('p2-post-reboot-' + $stamp + '.json')
$errorPath = Join-Path $reports ('p2-post-reboot-' + $stamp + '-error.json')
$inputPath = Join-Path $reports ('.p2-verify-input-' + $stamp + '.tmp')
$resultCode = 2
$pythonExitCode = $null
$pythonOutput = @()
$failureException = $null
try {
    . (Join-Path $PSScriptRoot 'P2-ReadOnly.ps1')
    $registryPattern = '^PCI\\VEN_10DE&DEV_1E04(?:&SUBSYS_' + [regex]::Escape($gpu.subsystem_id) + ')?(?:&REV_[0-9A-F]{2})?$'
    $devicePattern = '^' + [regex]::Escape($gpu.pnp_instance_id) + '$'
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        if ($null -eq $boot) { throw 'LastBootUpTime is unavailable' }
        $data.last_boot_utc = $boot.ToUniversalTime().ToString('o')
    } catch { $issues.Add('last-boot: ' + $_.Exception.Message) }
    try {
        $data.nvidia_smi_executable = Resolve-P2NvidiaSmi
        if (-not $data.nvidia_smi_executable.trusted) { throw 'NVIDIA executable location/signature is unknown' }
        $smi = $data.nvidia_smi_executable.path
        $rows = @(& $smi '--query-gpu=uuid,pci.device_id,pci.sub_device_id' '--format=csv,noheader,nounits' 2>&1)
        if ($LASTEXITCODE -ne 0) { throw 'nvidia-smi identity query failed' }
        $targets = @($rows | ConvertFrom-Csv -Header uuid,device,subsystem | Where-Object {
            $_.device.Trim() -ieq '0x1E0410DE' -and $_.subsystem.Trim() -ieq ('0x' + $gpu.subsystem_id) -and $_.uuid.Trim() -ieq $gpu.uuid
        })
        if ($targets.Count -ne 1) { throw 'Exactly one nvidia-smi target is required' }
        $uuid = $targets[0].uuid.Trim()
        if ($uuid -notmatch '^GPU-[0-9a-f-]+$') { throw 'Unexpected GPU UUID' }
        $data.nvidia_smi_target = @{uuid=$uuid; pci_device_id=$targets[0].device.Trim(); pci_sub_device_id=$targets[0].subsystem.Trim()}
        $output = @(& $smi '-q' '-i' $uuid 2>&1)
        $data.nvidia_smi_exit_code = $LASTEXITCODE
        $data.nvidia_smi_q = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ($LASTEXITCODE -ne 0) { throw 'nvidia-smi -q failed' }
    } catch { $issues.Add('nvidia-smi: ' + $_.Exception.Message) }
    try {
        $devices = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop | Where-Object {
            $_.InstanceId -match $devicePattern
        })
        if ($devices.Count -ne 1) { throw 'Exactly one present target PnP device is required' }
        $device = $devices[0]
        $problem = Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction Stop
        if ($null -eq $problem.Data) { throw 'PnP ProblemCode is unavailable' }
        $driver = Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_Driver' -ErrorAction Stop
        if ([string]$driver.Data -notmatch '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\[0-9]{4}$') { throw 'Invalid or missing PnP Driver property' }
        $data.pnp_devices = @(@{instance_id=$device.InstanceId; status=[string]$device.Status; problem_code=[int]$problem.Data; driver_key='HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\' + [string]$driver.Data})
    } catch { $issues.Add('pnp: ' + $_.Exception.Message) }
    if ($null -ne $data.last_boot_utc) {
        $data.system_log = Get-P2SystemLogEvidence -Boot $boot
        $data.display_4101_count_since_boot = $data.system_log.display_4101_count
        $data.nvlddmkm_error_count_since_boot = $data.system_log.nvlddmkm_error_count
        if (-not $data.system_log.complete) { $issues.Add('system-log: ' + $data.system_log.error) }
    }
    try {
        $class = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        $adapters = @(Get-ChildItem -LiteralPath $class -Name -ErrorAction Stop | Where-Object { $_ -match '^[0-9]{4}$' } | ForEach-Object {
            $key = Get-Item -LiteralPath ($class + '\' + $_) -ErrorAction Stop
            try {
                $matching = [string]$key.GetValue('MatchingDeviceId', $null)
                if ($matching -match $registryPattern) {
                    $value = @{exists=$false; type=$null; data=$null}
                    if (@($key.GetValueNames()) -contains 'EnableGpuFirmware') {
                        $value = @{exists=$true; type=[string]$key.GetValueKind('EnableGpuFirmware'); data=$key.GetValue('EnableGpuFirmware', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
                    }
                    @{key=$key.Name; matching_device_id=$matching; value=$value}
                }
            } finally { $key.Close() }
        })
        if ($adapters.Count -ne 1) { throw 'Exactly one target registry key is required' }
        if ($null -eq $data.pnp_devices -or $data.pnp_devices[0].driver_key -ine $adapters[0].key) { throw 'Present PnP driver key does not match registry key' }
        $data.gsp_registry = $adapters[0]
    } catch { $issues.Add('registry: ' + $_.Exception.Message) }
    try {
        $backupPath = Join-Path $reports 'p2-gsp-backup.json'
        if ([IO.File]::Exists($backupPath)) {
            $backup = [IO.File]::ReadAllText($backupPath) | ConvertFrom-Json -ErrorAction Stop
            if ($backup.gpu.uuid -ine $gpu.uuid -or $backup.gpu.pnp_instance_id -ine $gpu.pnp_instance_id -or
                [string]::IsNullOrWhiteSpace($backup.created_at_utc)) { throw 'GSP backup target or timestamp mismatch' }
            $data['gsp_change_utc'] = $backup.created_at_utc
        }
    } catch { $issues.Add('backup: ' + $_.Exception.Message) }
    $data.collection_errors = @($issues.ToArray())
    [IO.Directory]::CreateDirectory($reports) | Out-Null
    [IO.File]::WriteAllText($inputPath, ($data | ConvertTo-Json -Depth 16), $utf8)
    Push-Location -LiteralPath $root
    try {
        $pythonOutput = @(& $pythonExe -X utf8 -m p2.verify --input $inputPath --report $reportPath)
        $pythonExitCode = $LASTEXITCODE
    } finally { Pop-Location }
    $pythonOutput | ForEach-Object { Write-Host $_ }
    if ($null -eq $pythonExitCode -or $pythonExitCode -lt 0 -or $pythonExitCode -ge 2) {
        throw ('Python verification failed with exit code ' + $pythonExitCode)
    }
    # Exit 1 means an assessment with unmet criteria, never a missing/invalid report.
    if (-not [IO.File]::Exists($reportPath)) { throw 'Verification result report was not created' }
    $report = [IO.File]::ReadAllText($reportPath, $utf8) | ConvertFrom-Json
    if ($report.gsp_mode_established -isnot [bool] -or $report.unmet_criteria -isnot [array] -or
        ($pythonExitCode -eq 0 -and (-not $report.gsp_mode_established -or $report.unmet_criteria.Count -ne 0)) -or
        ($pythonExitCode -eq 1 -and ($report.gsp_mode_established -or $report.unmet_criteria.Count -eq 0))) {
        throw 'Verification result report does not match its exit code'
    }
    $resultCode = $pythonExitCode
    [IO.File]::Delete($inputPath)
} catch {
    $data.collection_errors = @($issues.ToArray())
    $failureException = @{type=$_.Exception.GetType().FullName; message=$_.Exception.Message; detail=$_.ToString(); script_stack_trace=$_.ScriptStackTrace}
    $resultCode = if ($null -ne $pythonExitCode -and $pythonExitCode -ge 2) { $pythonExitCode } else { 2 }
    try {
        $failure = $null
        if ([IO.File]::Exists($errorPath)) {
            try { $failure = [IO.File]::ReadAllText($errorPath, $utf8) | ConvertFrom-Json } catch { }
        }
        if ($null -eq $failure) {
            $failure = [pscustomobject]@{status='tool_failed'; snapshot=$data; exception=$failureException; read_only=$true; settings_changed=$false; restart_performed=$false}
        }
        $failure | Add-Member NoteProperty collected_data $data -Force
        $failure | Add-Member NoteProperty powershell_exception $failureException -Force
        $failure | Add-Member NoteProperty python_exit_code $pythonExitCode -Force
        $failure | Add-Member NoteProperty python_output $pythonOutput -Force
        [IO.Directory]::CreateDirectory($reports) | Out-Null
        [IO.File]::WriteAllText($errorPath, ($failure | ConvertTo-Json -Depth 32), $utf8)
        Write-Host $errorPath
        if ([IO.File]::Exists($inputPath)) { [IO.File]::Delete($inputPath) }
    } catch {
        $resultCode = 3
        [Console]::Error.WriteLine('Error report could not be saved: ' + $_.Exception.Message)
        [Console]::Error.WriteLine('Verification exception: ' + $failureException.message)
        [Console]::Error.WriteLine('Retained input (if created): ' + $inputPath)
    }
}
if ($resultCode -eq 0) { Write-Host 'GSP mode verified.' }
elseif ($resultCode -eq 1) { Write-Host 'GSP mode criteria not met.' }
else { Write-Host 'Verification failed; review the retained report.' }
exit $resultCode
