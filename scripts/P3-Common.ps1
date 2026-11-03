# Dot-source only: definitions have no device or filesystem side effects.
function Get-P3Stamp { [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '-' + [Guid]::NewGuid().ToString('N') }
function Get-P3HashText([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Read-P3Json([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
function Write-P3Json([string]$Path, $Data) {
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($Data | ConvertTo-Json -Depth 40))
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Test-P3Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-P3Identity($Disk) {
    # Stable identity digest; disk numbers and drive letters are excluded.
    Get-P3HashText (([string]$Disk.UniqueId)+'|'+([string]$Disk.FriendlyName)+'|'+([string]$Disk.Size)+'|'+([string]$Disk.BusType))
}
function Get-P3Inventory([string]$WorkspaceRoot) {
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $pageLetters = @()
    try { $pageLetters = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop | ForEach-Object {
        if ($_.Name -notmatch '^([A-Za-z]):\\') { throw 'Pagefile path cannot be mapped' }
        $Matches[1].ToUpperInvariant()
    }) } catch { $errors.Add('pagefile-query: ' + $_.Exception.Message) }
    $records = @()
    try {
        $records = @(Get-Disk -ErrorAction Stop | ForEach-Object {
            $d = $_; $parts = @(); $diskErrors = New-Object 'System.Collections.Generic.List[string]'
            try {
                $parts = @(Get-Partition -DiskNumber $d.Number -ErrorAction Stop | ForEach-Object {
                    $p = $_; $vols = @()
                    try {
                        $vols = @($p | Get-Volume -ErrorAction Stop | Where-Object { $null -ne $_ } | ForEach-Object {
                            $v = $_; $entries = @(); $listingError = $null
                            try { $entries = @(Get-ChildItem -LiteralPath $v.Path -Force -ErrorAction Stop | ForEach-Object {
                                @{name=$_.Name; directory=[bool]$_.PSIsContainer; bytes=$(if ($_.PSIsContainer) { $null } else { [long]$_.Length }); attributes=[string]$_.Attributes}
                            }) } catch { $listingError = $_.Exception.Message }
                            [pscustomobject]@{path=[string]$v.Path; unique_id=[string]$v.UniqueId; drive_letter=[string]$v.DriveLetter;
                                file_system=[string]$v.FileSystem; label=[string]$v.FileSystemLabel; size_bytes=[long]$v.Size;
                                free_bytes=[long]$v.SizeRemaining; allocation_unit_bytes=[long]$v.AllocationUnitSize;
                                root_entries=$entries; root_listing_error=$listingError}
                        })
                    } catch { $diskErrors.Add('volume-query: ' + $_.Exception.Message) }
                    [pscustomobject]@{number=[int]$p.PartitionNumber; disk_number=[int]$p.DiskNumber; size_bytes=[long]$p.Size;
                        offset=[long]$p.Offset; drive_letter=[string]$p.DriveLetter; access_paths=@($p.AccessPaths);
                        gpt_type=([string]$p.GptType).Trim('{}').ToLowerInvariant(); mbr_type=[int]$p.MbrType;
                        is_boot=[bool]$p.IsBoot; is_system=[bool]$p.IsSystem; volumes=$vols}
                })
            } catch { $diskErrors.Add('partition-query: ' + $_.Exception.Message) }
            [pscustomobject]@{number=[int]$d.Number; friendly_name=[string]$d.FriendlyName; serial_number=[string]$d.SerialNumber;
                unique_id=[string]$d.UniqueId; identity_sha256=(Get-P3Identity $d); bus_type=[string]$d.BusType;
                size_bytes=[long]$d.Size; partition_style=[string]$d.PartitionStyle; partition_count=[int]$d.NumberOfPartitions;
                is_boot=[bool]$d.IsBoot; is_system=[bool]$d.IsSystem; is_offline=[bool]$d.IsOffline; is_read_only=[bool]$d.IsReadOnly;
                partitions=$parts; errors=@($diskErrors.ToArray())}
        })
    } catch { $errors.Add('disk-query: ' + $_.Exception.Message) }
    [pscustomobject]@{schema_version=1; observed_at_utc=[DateTime]::UtcNow.ToString('o'); disks=$records;
        errors=@($errors.ToArray()); pagefile_letters=$pageLetters; windows_letter=$env:SystemDrive.Substring(0,1);
        workspace_letter=[IO.Path]::GetPathRoot($WorkspaceRoot).Substring(0,1)}
}
function Get-P3Exclusions($Disk, $Inventory, $MediaPolicy, $P3Policy, [string]$WorkspaceRoot) {
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    if ($Disk.identity_sha256 -in @($MediaPolicy.protected_disk_identity_sha256)) { $reasons.Add('media-policy-protected') }
    if ($Disk.bus_type -ine 'USB') { $reasons.Add('not-usb') }
    if ($Disk.is_boot -or $Disk.is_system) { $reasons.Add('boot-or-system-disk') }
    if ([string]::IsNullOrWhiteSpace($Disk.unique_id)) { $reasons.Add('missing-unique-id') }
    if (@($Disk.errors).Count -gt 0 -or @($Disk.partitions).Count -ne $Disk.partition_count) { $reasons.Add('incomplete-disk-inventory') }
    foreach ($p in @($Disk.partitions)) {
        if ($p.is_boot -or $p.is_system -or $p.gpt_type -in @('c12a7328-f81f-11d2-ba4b-00a0c93ec93b','e3c9e316-0b5c-4db8-817d-f92df00215ae','de94bba4-06d1-4d40-a16a-bfd50179d6ac') -or $p.mbr_type -in @(0x27,0xef)) { $reasons.Add('protected-partition') }
        $letters = @([string]$p.drive_letter) + @($p.access_paths | Where-Object { $_ -match '^[A-Za-z]:\\$' } | ForEach-Object { $_.Substring(0,1) })
        foreach ($letter in $letters) {
            if (-not $letter) { continue }
            if ($letter -ieq $Inventory.windows_letter -or $letter -ieq $Inventory.workspace_letter) { $reasons.Add('windows-or-workspace-volume') }
            if ($letter -in @($Inventory.pagefile_letters)) { $reasons.Add('pagefile-volume') }
        }
    }
    $reasons.ToArray()
}
function Get-P3Selection($Inventory, $MediaPolicy, $P3Policy, [string]$WorkspaceRoot) {
    $protected = @($MediaPolicy.protected_disk_identity_sha256)
    if ($protected.Count -eq 0 -or @($protected | Sort-Object -Unique).Count -ne $protected.Count -or
        @($protected | Where-Object { $_ -isnot [string] -or $_ -notmatch '^[a-f0-9]{64}$' }).Count) { throw 'exclusion-policy-invalid' }
    $candidates = @(); $excluded = @()
    foreach ($d in @($Inventory.disks)) {
        $why = @(Get-P3Exclusions $d $Inventory $MediaPolicy $P3Policy $WorkspaceRoot)
        if ($why.Count) { $excluded += @{disk_number=$d.number; identity_sha256=$d.identity_sha256; reasons=$why} }
        else { $candidates += $d }
    }
    $reason = $null
    if (@($Inventory.errors).Count) { $reason = 'inventory-incomplete' }
    elseif ($candidates.Count -ne 1) { $reason = 'candidate-count-' + $candidates.Count }
    [pscustomobject]@{status=$(if ($reason) { 'refused' } else { 'identified' }); reason=$reason;
        candidate_count=$candidates.Count; candidates=$candidates; excluded=$excluded}
}
function Get-P3Binding($Disk) {
    # Number and drive letters may change; stable partition and Volume GUID mapping may not.
    $parts = @($Disk.partitions | Sort-Object number | ForEach-Object {
        [ordered]@{number=$_.number; offset=$_.offset; size_bytes=$_.size_bytes; gpt_type=$_.gpt_type; mbr_type=$_.mbr_type;
            volumes=@($_.volumes | ForEach-Object { [ordered]@{path=$_.path; unique_id=$_.unique_id; size_bytes=$_.size_bytes; file_system=$_.file_system} })}
    })
    $text = [ordered]@{unique_id=$Disk.unique_id; serial_number=$Disk.serial_number; friendly_name=$Disk.friendly_name;
        size_bytes=$Disk.size_bytes; bus_type=$Disk.bus_type; partition_style=$Disk.partition_style; partitions=$parts} | ConvertTo-Json -Depth 16 -Compress
    Get-P3HashText $text
}
function Resolve-P3Pinned($Inventory, $Inspect, $Policy, $MediaPolicy, [string]$WorkspaceRoot) {
    if ([string]::IsNullOrWhiteSpace($Policy.volume_guid_path) -or $Policy.identity_sha256 -notmatch '^[a-f0-9]{64}$' -or $Policy.binding_sha256 -notmatch '^[a-f0-9]{64}$') { throw 'p3-policy-unbound' }
    if ($Inspect.selection.status -ne 'identified' -or @($Inspect.selection.candidates).Count -ne 1 -or @($Inspect.inventory.errors).Count) { throw 'inspect-not-identified' }
    $old = $Inspect.selection.candidates[0]
    if ($old.identity_sha256 -ne $Policy.identity_sha256 -or (Get-P3Binding $old) -ne $Policy.binding_sha256) { throw 'inspect-policy-identity-mismatch' }
    $selected = Get-P3Selection $Inventory $MediaPolicy $Policy $WorkspaceRoot
    if ($selected.status -ne 'identified') { throw $selected.reason }
    $disk = $selected.candidates[0]
    if ($disk.identity_sha256 -ne $Policy.identity_sha256 -or (Get-P3Binding $disk) -ne $Policy.binding_sha256) { throw 'live-identity-mismatch' }
    if ($disk.is_offline -or $disk.is_read_only) { throw 'disk-offline-or-readonly' }
    if (@($disk.partitions).Count -ne 1 -or @($disk.partitions[0].volumes).Count -ne 1) { throw 'single-partition-and-volume-required' }
    $vol = $disk.partitions[0].volumes[0]
    if ($vol.path -notmatch '^\\\\\?\\Volume\{[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\}\\$') { throw 'volume-guid-required' }
    if ($Policy.volume_guid_path -cne $vol.path) { throw 'pinned-volume-guid-mismatch' }
    $vol
}
function Test-P3SystemDirectory([string]$Name, $Directory, [string]$Attributes) {
    $Name -ieq 'System Volume Information' -and ($Directory -is [bool] -and $Directory) -and $Attributes -notmatch 'ReparsePoint'
}
function Assert-P3Empty($Volume) {
    if ($Volume.file_system -ine 'FAT32') { throw 'filesystem-not-fat32-human-format-decision-required' }
    if ($null -ne $Volume.root_listing_error) { throw 'root-listing-unavailable' }
    if (@($Volume.root_entries | Where-Object { $_.name -ieq 'EFI' }).Count) { throw 'existing-efi-human-decision-required' }
    if (@($Volume.root_entries | Where-Object { -not (Test-P3SystemDirectory $_.name $_.directory $_.attributes) }).Count) { throw 'existing-files-human-decision-required' }
    if ($Volume.allocation_unit_bytes -lt 512 -or $Volume.allocation_unit_bytes -gt 65536 -or
        (($Volume.allocation_unit_bytes -band ($Volume.allocation_unit_bytes - 1)) -ne 0)) { throw 'allocation-unit-unknown' }
}
function Assert-P3NoReparse([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('reparse-point-refused: ' + $Path) }
}
function Get-P3AllowedFiles {
    @('EFI/BOOT/BOOTX64.EFI','booter_load_tu10x.bin','chain-target.txt','fwimage_tu10x.bin','fwsignature_tu10x.bin','gsp_boot_desc_tu10x.bin','gsp_boot_tu10x.bin','no-reconnect.txt','sec2_bl_tu10x.bin','tx-require-d0.txt','tx-select-bdf.txt','v67-tu10x-four-plm.bin')
}
function Assert-P3Manifest($Policy) {
    $allowed = @(Get-P3AllowedFiles)
    $entries = @($Policy.payload_files)
    if ($entries.Count -ne $allowed.Count -or @($entries.path | Sort-Object -Unique).Count -ne $allowed.Count) { throw 'payload-file-set-or-armed-marker-refused' }
    foreach ($entry in $entries) {
        if ($entry.path -cnotin $allowed -or $entry.sha256 -notmatch '^[a-f0-9]{64}$' -or
            ($entry.bytes -isnot [int] -and $entry.bytes -isnot [long]) -or $entry.bytes -le 0) { throw 'unexpected-or-experimental-payload' }
        if ($entry.bytes -gt 4294967295L) { throw 'payload-file-exceeds-fat32-limit' }
    }
}
function Get-P3Payload([string]$Source, $Policy) {
    Assert-P3Manifest $Policy
    Assert-P3NoReparse $Source
    $items = @(Get-ChildItem -LiteralPath $Source -Recurse -Force -ErrorAction Stop)
    foreach ($item in $items) {
        Assert-P3NoReparse $item.FullName
        $relativePath = $item.FullName.Substring($Source.TrimEnd('\').Length + 1).Replace('\','/')
        if ($item.PSIsContainer -and $relativePath -cnotin @('EFI','EFI/BOOT')) { throw 'unexpected-directory-or-experimental-marker' }
    }
    $files = @($items | Where-Object { -not $_.PSIsContainer })
    $allowed = @(Get-P3AllowedFiles)
    if ($files.Count -ne 12 -or @($Policy.payload_files).Count -ne 12 -or
        @($Policy.payload_files.path | Sort-Object -Unique).Count -ne 12) { throw 'payload-file-set-or-armed-marker-refused' }
    $result = @(); $total = 0L
    foreach ($entry in @($Policy.payload_files)) {
        if ($entry.path -cnotin $allowed -or $entry.sha256 -notmatch '^[a-f0-9]{64}$' -or
            ($entry.bytes -isnot [int] -and $entry.bytes -isnot [long]) -or $entry.bytes -le 0) { throw 'unexpected-or-experimental-payload' }
        $path = Join-Path $Source $entry.path
        $relative = @($files | Where-Object { $_.FullName.Substring($Source.TrimEnd('\').Length + 1).Replace('\','/') -ceq $entry.path })
        if ($relative.Count -ne 1 -or $relative[0].Length -ne $entry.bytes -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.sha256) { throw ('source-hash-or-file-set-mismatch: ' + $entry.path) }
        $total += [long]$entry.bytes; $result += $entry
    }
    $result
}
function Copy-P3CreateNew([string]$Source, [string]$Destination) {
    $inputFile = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $outputFile = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $inputFile.CopyTo($outputFile); $outputFile.Flush($true) } finally { $outputFile.Dispose() }
    } finally { $inputFile.Dispose() }
}
function Get-P3PayloadPaths([string]$Destination, [string]$RelativePath) {
    # String-only calculation: Path/Provider APIs can strip a Volume GUID root's final backslash.
    $root = $Destination.Replace('/','\').TrimEnd('\') + '\'
    $relative = $RelativePath.Replace('/','\')
    $parts = @($relative.Split('\'))
    if ([string]::IsNullOrWhiteSpace($Destination) -or
        @($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.','..') -or $_ -match '[:*?"<>|]' }).Count) {
        throw 'invalid-payload-relative-path'
    }
    $directories = @()
    $parent = $root
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $parent = $root + ($parts[0..$i] -join '\')
        $directories += $parent
    }
    [pscustomobject]@{destination_root=$root; target=($root + $relative); parent=$parent; directories=$directories}
}
function Copy-P3Payload([string]$Source, [string]$Destination, $Files, $Receipt) {
    # Destination is the validated Volume GUID root in production. Tests use a temporary directory.
    $Destination = $Destination.Replace('/','\').TrimEnd('\') + '\'
    Assert-P3NoReparse $Destination
    if (@(Get-ChildItem -LiteralPath $Destination -Force -ErrorAction Stop | Where-Object {
        -not (Test-P3SystemDirectory $_.Name $_.PSIsContainer ([string]$_.Attributes))
    }).Count) { throw 'destination-no-longer-empty' }
    foreach ($entry in @($Files | Sort-Object @{Expression={ $_.path.Replace('/','\') -eq 'EFI\BOOT\BOOTX64.EFI' }}, path)) {
        Assert-P3NoReparse $Destination
        $paths = Get-P3PayloadPaths $Destination $entry.path
        $target = $paths.target
        # Root files need no directory creation. Check EFI before touching EFI\BOOT.
        foreach ($directory in $paths.directories) {
            if (-not [IO.Directory]::Exists($directory)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
            Assert-P3NoReparse $directory
        }
        $step = [ordered]@{path=$entry.path; status='copy-attempted'; sha256=$null}
        $Receipt.steps.Add($step)
        Copy-P3CreateNew (Get-P3PayloadPaths $Source $entry.path).target $target
        $step.sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ((Get-Item -LiteralPath $target -Force).Length -ne $entry.bytes -or $step.sha256 -ne $entry.sha256) { throw ('readback-hash-mismatch: ' + $entry.path) }
        $step.status = 'verified'
    }
    # Read every destination again after the entire copy, including the EFI copied last.
    foreach ($entry in $Files) {
        $target = (Get-P3PayloadPaths $Destination $entry.path).target
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash -ine $entry.sha256 -or
            (Get-Item -LiteralPath $target -Force).Length -ne $entry.bytes) { throw ('final-readback-mismatch: ' + $entry.path) }
    }
    # Do not enumerate Windows-managed metadata; it may deny access and is not payload.
    $actual = @(Get-ChildItem -LiteralPath $Destination -Force -ErrorAction Stop | ForEach-Object {
        Assert-P3NoReparse $_.FullName
        if (-not (Test-P3SystemDirectory $_.Name $_.PSIsContainer ([string]$_.Attributes))) {
            $_
            if ($_.PSIsContainer) { Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop }
        }
    })
    foreach ($item in $actual) { Assert-P3NoReparse $item.FullName }
    if (@($actual | Where-Object { -not $_.PSIsContainer }).Count -ne 12) { throw 'unexpected-file-after-copy' }
}
