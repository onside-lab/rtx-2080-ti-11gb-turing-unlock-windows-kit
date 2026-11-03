# Read-only collection functions. Dot-sourcing performs no device, registry or log query.
function Resolve-P2NvidiaSmi {
    param([string]$WindowsRoot = $env:SystemRoot)
    $evidence = [ordered]@{trusted=$false; path=$null; signature=$null; attempts=@()}
    try {
        $system = Join-Path $WindowsRoot 'System32\nvidia-smi.exe'
        $candidates = @($system)
        if (-not (Test-Path -LiteralPath $system -PathType Leaf)) {
            $store = Join-Path $WindowsRoot 'System32\DriverStore\FileRepository'
            $candidates = @(Get-ChildItem -LiteralPath $store -Directory -Filter 'nv_dispi.inf_*' -ErrorAction Stop |
                Sort-Object FullName | ForEach-Object {
                    $candidate = Join-Path $_.FullName 'nvidia-smi.exe'
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate }
                })
        }
        foreach ($candidate in $candidates) {
            $attempt = [ordered]@{path=[IO.Path]::GetFullPath($candidate); status=$null; subject=$null; thumbprint=$null; error=$null}
            try {
                $signature = Get-AuthenticodeSignature -LiteralPath $attempt.path -ErrorAction Stop
                $attempt.status = [string]$signature.Status
                if ($null -ne $signature.SignerCertificate) {
                    $attempt.subject = $signature.SignerCertificate.Subject
                    $attempt.thumbprint = $signature.SignerCertificate.Thumbprint
                }
                $nvidia = $attempt.subject -match '(?:^|,\s*)O=NVIDIA Corporation(?:,|$)'
                $whql = ($attempt.subject -match '(?:^|,\s*)CN=Microsoft Windows Hardware Compatibility Publisher(?:,|$)' -and
                         $attempt.subject -match '(?:^|,\s*)O=Microsoft Corporation(?:,|$)')
                $storePattern = '^' + [regex]::Escape((Join-Path $WindowsRoot 'System32\DriverStore\FileRepository\')) + 'nv_dispi\.inf_[^\\]+\\nvidia-smi\.exe$'
                $allowedPath = ($attempt.path -ieq [IO.Path]::GetFullPath($system) -or $attempt.path -match $storePattern)
                if ($allowedPath -and $attempt.status -eq 'Valid' -and ($nvidia -or $whql)) {
                    $evidence.trusted = $true
                    $evidence.path = $attempt.path
                    $evidence.signature = $attempt
                }
            } catch { $attempt.error = $_.Exception.Message }
            $evidence.attempts += @($attempt)
            if ($evidence.trusted) { break }
        }
    } catch { $evidence['error'] = $_.Exception.Message }
    return $evidence
}

function Get-P2PresentDisplay {
    param($Gpu)
    $ErrorActionPreference = 'Stop'
    $utf8 = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8
    $class = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Class\'
    if ($null -ne $Gpu) {
        Get-P2TargetSmi $Gpu | Out-Null
        $nvidia = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop | Where-Object { $_.InstanceId -match '^PCI\\VEN_10DE&' })
        if ($nvidia.Count -ne 1 -or $nvidia[0].InstanceId -ine $Gpu.pnp_instance_id) { throw 'single-configured-nvidia-pnp-device-required' }
    }
    foreach ($device in @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop)) {
        if (($device.InstanceId -replace '\\[^\\]+$','') -notmatch '^PCI\\VEN_10DE&DEV_1E04&SUBSYS_[0-9A-F]{8}(?:&REV_[0-9A-F]{2})?$') { continue }
        $driver = Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_Driver' -ErrorAction Stop
        if ([string]$driver.Data -notmatch '^\{4d36e968-e325-11ce-bfc1-08002be10318\}\\[0-9]{4}$') { throw 'Invalid or missing PnP Driver property' }
        @{instance_id=[string]$device.InstanceId; driver_key=$class + [string]$driver.Data}
    }
}

function Get-P2TargetSmi($Gpu) {
    $executable = Resolve-P2NvidiaSmi
    if (-not $executable.trusted) { throw 'trusted-nvidia-smi-required' }
    $rows = @(& $executable.path '--query-gpu=uuid,pci.device_id,pci.sub_device_id' '--format=csv,noheader,nounits' 2>&1)
    if ($LASTEXITCODE -ne 0 -or $rows.Count -ne 1) { throw 'single-nvidia-smi-device-required' }
    $targets = @($rows | ConvertFrom-Csv -Header uuid,device,subsystem | Where-Object {
        $_.uuid.Trim() -ieq $Gpu.uuid -and $_.device.Trim() -ieq '0x1E0410DE' -and $_.subsystem.Trim() -ieq ('0x' + $Gpu.subsystem_id)
    })
    if ($targets.Count -ne 1) { throw 'configured-nvidia-smi-target-mismatch' }
    @{executable=$executable; target=@{uuid=$targets[0].uuid.Trim(); pci_device_id=$targets[0].device.Trim(); pci_sub_device_id=$targets[0].subsystem.Trim()}}
}

function Get-P2EventCount {
    param([hashtable]$Filter)
    try { return @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop).Count }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return 0 }
        throw
    }
}

function Get-P2SystemLogEvidence {
    param([DateTime]$Boot)
    $result = [ordered]@{complete=$false; oldest_utc=$null; system_clear_count=$null; display_4101_count=$null; nvlddmkm_error_count=$null; error=$null}
    try {
        $oldest = Get-WinEvent -LogName System -Oldest -MaxEvents 1 -ErrorAction Stop
        if ($null -eq $oldest.TimeCreated) { throw 'Oldest System event is unavailable' }
        $result.oldest_utc = $oldest.TimeCreated.ToUniversalTime().ToString('o')
        if ($oldest.TimeCreated -gt $Boot) { throw 'System log does not cover last boot' }
        # Any Eventlog 104 is conservative evidence of a possible gap, including unreadable channel metadata.
        $result.system_clear_count = Get-P2EventCount @{LogName='System'; ProviderName='Microsoft-Windows-Eventlog'; Id=104; StartTime=$Boot}
        if ($result.system_clear_count -ne 0) { throw 'Eventlog 104 after last boot' }
        $tdr = Get-P2EventCount @{LogName='System'; ProviderName='Display'; Id=4101; StartTime=$Boot}
        $nv = Get-P2EventCount @{LogName='System'; ProviderName='nvlddmkm'; Level=2; StartTime=$Boot}
        # Recheck after counting so a clear/rollover during collection also fails closed.
        $oldestAfter = Get-WinEvent -LogName System -Oldest -MaxEvents 1 -ErrorAction Stop
        if ($null -eq $oldestAfter.TimeCreated -or $oldestAfter.TimeCreated -gt $Boot) { throw 'System log coverage changed during collection' }
        $result.system_clear_count = Get-P2EventCount @{LogName='System'; ProviderName='Microsoft-Windows-Eventlog'; Id=104; StartTime=$Boot}
        if ($result.system_clear_count -ne 0) { throw 'Eventlog 104 during collection' }
        $result.display_4101_count = $tdr
        $result.nvlddmkm_error_count = $nv
        $result.complete = $true
    } catch { $result.error = $_.Exception.Message }
    return $result
}
