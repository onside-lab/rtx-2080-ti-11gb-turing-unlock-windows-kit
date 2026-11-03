param([string]$Root, [string]$Scratch)
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'scripts/P3-Common.ps1')
$results = New-Object 'System.Collections.Generic.List[object]'
function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $results.Add(@{name=$Name; passed=$true}) }
    catch { $results.Add(@{name=$Name; passed=$false; error=$_.ToString(); stack=$_.ScriptStackTrace}) }
}
function Require($Condition) { if (-not $Condition) { throw 'assertion failed' } }
function Refuses([scriptblock]$Body, [string]$Pattern) {
    $message = $null
    try { & $Body | Out-Null } catch { $message = $_.Exception.Message }
    if ($null -eq $message -or $message -notlike ('*' + $Pattern + '*')) { throw ('Expected refusal ' + $Pattern + ', got: ' + $message) }
}
function Clone($Value) { $Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json }
$media = [pscustomobject]@{protected_disk_identity_sha256=@(('c'*64),('d'*64))}
$policy = [pscustomobject]@{identity_sha256=$null;binding_sha256=$null;volume_guid_path=$null;inspect_report=$null;inspect_sha256=$null;payload_files=@()}
$known = [pscustomobject]@{disks=@()}
$vol = [pscustomobject]@{path='\\?\Volume{12345678-1234-1234-1234-123456789abc}\'; unique_id='mock-volume';
    file_system='FAT32'; label='SIMULATED P3'; size_bytes=7990000000L; free_bytes=7900000000L; allocation_unit_bytes=4096;
    root_entries=@(); root_listing_error=$null}
$usb = [pscustomobject]@{number=3; unique_id='SIMULATED-ONLY-USB'; friendly_name='SIMULATED-ONLY-USB'; serial_number='MOCK';
    bus_type='USB'; size_bytes=8000000000L; partition_style='MBR'; partition_count=1; is_boot=$false; is_system=$false;
    is_offline=$false; is_read_only=$false; errors=@(); identity_sha256=('a'*64);
    partitions=@([pscustomobject]@{number=1; disk_number=3; offset=1048576; size_bytes=7990000000L; drive_letter='Z'; access_paths=@('Z:\');
        gpt_type=''; mbr_type=12; is_boot=$false; is_system=$false; volumes=@($vol)})}
$inventory = [pscustomobject]@{disks=@($known.disks)+@($usb); errors=@(); pagefile_letters=@('W'); windows_letter='W'; workspace_letter='X'}
$inspect = [pscustomobject]@{inventory=(Clone $inventory); selection=(Get-P3Selection $inventory $media)}
$bound = Clone $policy
$bound.identity_sha256 = $usb.identity_sha256
$bound.binding_sha256 = Get-P3Binding $usb
$bound.volume_guid_path = $vol.path
$savedPolicy = Clone $bound
[IO.Directory]::CreateDirectory($Scratch) | Out-Null
$savedPolicy.inspect_report = Join-Path $Scratch 'inspect.json'
Write-P3Json $savedPolicy.inspect_report $inspect
$savedPolicy.inspect_sha256 = (Get-FileHash -LiteralPath $savedPolicy.inspect_report -Algorithm SHA256).Hash.ToLowerInvariant()
Check 'protected-list-size-is-configurable' {
    foreach ($count in @(1,2,4)) { $m=[pscustomobject]@{protected_disk_identity_sha256=@(1..$count | ForEach-Object { ([string]$_)*64 })}; Require ((Get-P3Selection $inventory $m).status -eq 'identified') }
}
Check 'empty-protection-list-refused' { Refuses { Get-P3Selection $inventory ([pscustomobject]@{protected_disk_identity_sha256=@()}) } 'exclusion-policy-invalid' }
Check 'zero-candidates' { $i=Clone $inventory; $i.disks=@($known.disks); Require ((Get-P3Selection $i $media).reason -eq 'candidate-count-0') }
Check 'two-candidates' { $i=Clone $inventory; $i.disks += @(Clone $usb); Require ((Get-P3Selection $i $media).reason -eq 'candidate-count-2') }
Check 'protected-policy-hash' { $u=Clone $usb; $u.identity_sha256=$media.protected_disk_identity_sha256[0]; Require (@(Get-P3Exclusions $u $inventory $media) -contains 'media-policy-protected') }
Check 'boot-system-pagefile-esp' {
    foreach ($flag in @('is_boot','is_system')) { $u=Clone $usb; $u.$flag=$true; Require (@(Get-P3Exclusions $u $inventory $media) -contains 'boot-or-system-disk') }
    $u=Clone $usb; $u.partitions[0].drive_letter='W'; Require (@(Get-P3Exclusions $u $inventory $media) -contains 'pagefile-volume')
    $u=Clone $usb; $u.partitions[0].gpt_type='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'; Require (@(Get-P3Exclusions $u $inventory $media) -contains 'protected-partition')
}
Check 'unknown-inventory-stops' { $i=Clone $inventory; $i.errors=@('pagefile denied'); Require ((Get-P3Selection $i $media).reason -eq 'inventory-incomplete') }
Check 'unbound-policy-stops' {
    $p=Clone $policy; $p.identity_sha256=$null; $p.binding_sha256=$null; $p.inspect_report=$null; $p.inspect_sha256=$null
    Refuses { Resolve-P3Pinned $inventory $inspect $p $media } 'p3-policy-unbound'
}
Check 'saved-bound-policy-matches-native-fingerprints' {
    Require ((Get-FileHash -LiteralPath $savedPolicy.inspect_report -Algorithm SHA256).Hash -ieq $savedPolicy.inspect_sha256)
    $s=Read-P3Json $savedPolicy.inspect_report
    Require ((Get-P3Binding $s.selection.candidates[0]) -eq $savedPolicy.binding_sha256)
    Require ((Resolve-P3Pinned $inventory $s $savedPolicy $media).path -eq $vol.path)
}
Check 'saved-inspect-binding-mismatch-refused' {
    $p=Clone $savedPolicy; $p.binding_sha256=('b'*64)
    $s=Read-P3Json $p.inspect_report
    Refuses { Resolve-P3Pinned $inventory $s $p $media } 'inspect-policy-identity-mismatch'
}
Check 'same-identity-pass' { Require ((Resolve-P3Pinned $inventory $inspect $bound $media).path -eq $vol.path) }
Check 'serial-changed-stops' { $i=Clone $inventory; $i.disks[0].serial_number='OTHER'; Refuses { Resolve-P3Pinned $i $inspect $bound $media } 'live-identity-mismatch' }
Check 'identifier-changed-stops' { $i=Clone $inventory; $i.disks[0].identity_sha256=('b'*64); Refuses { Resolve-P3Pinned $i $inspect $bound $media } 'live-identity-mismatch' }
Check 'volume-remap-stops' { $i=Clone $inventory; $i.disks[0].partitions[0].volumes[0].path='\\?\Volume{aaaaaaaa-1234-1234-1234-123456789abc}\'; Refuses { Resolve-P3Pinned $i $inspect $bound $media } 'live-identity-mismatch' }
Check 'refused-inspect-stops' { $s=Clone $inspect; $s.selection.status='refused'; Refuses { Resolve-P3Pinned $inventory $s $bound $media } 'inspect-not-identified' }
Check 'fat32-empty-pass' { Assert-P3Empty $vol }
Check 'exfat-ntfs-fat-stop' { foreach ($fs in @('exFAT','NTFS','FAT','')) { $v=Clone $vol; $v.file_system=$fs; Refuses { Assert-P3Empty $v } 'filesystem-not-fat32' } }
Check 'existing-files-stop' { $v=Clone $vol; $v.root_entries=@(@{name='keep.txt'}); Refuses { Assert-P3Empty $v } 'existing-files' }
Check 'existing-efi-stop' { $v=Clone $vol; $v.root_entries=@(@{name='eFi'}); Refuses { Assert-P3Empty $v } 'existing-efi' }
Check 'unknown-root-stop' { $v=Clone $vol; $v.root_listing_error='denied'; Refuses { Assert-P3Empty $v } 'root-listing-unavailable' }
# Tiny synthetic bytes only; no firmware or EFI artifact is used.
$source = Join-Path $Scratch 'payload'
[IO.Directory]::CreateDirectory($source) | Out-Null
$template = Read-P3Json (Join-Path $Root 'config/p3-usb-policy.example.json')
$policy.payload_files = @($template.payload_files | ForEach-Object {
    $path=Join-Path $source $_.path
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [IO.File]::WriteAllText($path, ('SYNTHETIC ONLY: ' + $_.path), (New-Object Text.UTF8Encoding($false)))
    [pscustomobject]@{path=$_.path;bytes=(Get-Item -LiteralPath $path).Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
})
Check 'synthetic-payload-twelve-hashes' { Require (@(Get-P3Payload $source $policy).Count -eq 12) }
Check 'fat32-single-file-limit-accepted' {
    $p=Clone $policy; $p.payload_files[0].bytes=4294967295L
    Assert-P3Manifest $p
}
Check 'fat32-oversized-manifest-refused-before-source-access' {
    $p=Clone $policy; $p.payload_files[0].bytes=4294967296L
    Refuses { Get-P3Payload (Join-Path $Scratch 'nonexistent-source') $p } 'payload-file-exceeds-fat32-limit'
}
Check 'empty-hash-refused' { $p=Clone $policy; $p.payload_files[0].sha256=''; Refuses { Get-P3Payload $source $p } 'unexpected-or-experimental-payload' }
Check 'missing-manifest-entry-refused' { $p=Clone $policy; $p.payload_files=@($p.payload_files | Select-Object -First 11); Refuses { Get-P3Payload $source $p } 'payload-file-set' }
Check 'svi-only-root-pass' { $v=Clone $vol; $v.root_entries=@(@{name='System Volume Information';directory=$true;attributes='Hidden, System, Directory'}); Assert-P3Empty $v }
Check 'svi-file-and-reparse-stop' {
    foreach ($entry in @(@{name='System Volume Information';directory=$false;attributes='Hidden'},@{name='System Volume Information';directory=$true;attributes='Directory, ReparsePoint'})) {
        $v=Clone $vol; $v.root_entries=@($entry); Refuses { Assert-P3Empty $v } 'existing-files'
    }
}
Check 'pinned-volume-required' { $p=Clone $bound; $p.volume_guid_path=$null; Refuses { Resolve-P3Pinned $inventory $inspect $p $media } 'p3-policy-unbound' }
Check 'pinned-volume-mismatch' { $p=Clone $bound; $p.volume_guid_path='different'; Refuses { Resolve-P3Pinned $inventory $inspect $p $media } 'pinned-volume-guid-mismatch' }
Check 'volume-guid-trailing-backslash-required' {
    $i=Clone $inventory; $u=$i.disks[0]; $u.partitions[0].volumes[0].path=$vol.path.TrimEnd('\')
    $p=Clone $bound; $p.binding_sha256=Get-P3Binding $u; $p.volume_guid_path=$u.partitions[0].volumes[0].path
    $s=[pscustomobject]@{inventory=$i;selection=(Get-P3Selection $i $media)}
    Refuses { Resolve-P3Pinned $i $s $p $media } 'volume-guid-required'
}
Check 'invalid-allocation-unit-stops' { $v=Clone $vol; $v.allocation_unit_bytes=123; Refuses { Assert-P3Empty $v } 'allocation-unit-unknown' }
Check 'offline-readonly-stops' { foreach ($flag in @('is_offline','is_read_only')) { $i=Clone $inventory; $i.disks[0].$flag=$true; Refuses { Resolve-P3Pinned $i $inspect $bound $media } 'disk-offline-or-readonly' } }
$tempSource = Join-Path $Scratch 'source'
[IO.Directory]::CreateDirectory($tempSource) | Out-Null
foreach ($entry in $policy.payload_files) {
    $to=Join-Path $tempSource $entry.path; [IO.Directory]::CreateDirectory((Split-Path -Parent $to)) | Out-Null
    Copy-P3CreateNew (Join-Path $source $entry.path) $to
}
Check 'armed-marker-stops' {
    $marker=Join-Path $tempSource 'i_know_what_i_am_doing.txt'; [IO.File]::WriteAllText($marker,'')
    Refuses { Get-P3Payload $tempSource $policy } 'payload-file-set-or-armed-marker-refused'
    [IO.File]::Delete($marker)
}
Check 'experimental-marker-stops' {
    $marker=Join-Path $tempSource 'tx-force-continue.txt'; [IO.File]::WriteAllText($marker,'')
    Refuses { Get-P3Payload $tempSource $policy } 'payload-file-set-or-armed-marker-refused'
    [IO.File]::Delete($marker)
}
Check 'armed-directory-stops' {
    $marker=Join-Path $tempSource 'i_know_what_i_am_doing.txt'; [IO.Directory]::CreateDirectory($marker) | Out-Null
    Refuses { Get-P3Payload $tempSource $policy } 'unexpected-directory-or-experimental-marker'
    [IO.Directory]::Delete($marker)
}
Check 'tampered-source-hash-stops' {
    $path=Join-Path $tempSource 'tx-select-bdf.txt'; [IO.File]::WriteAllText($path,'02:00.0')
    Refuses { Get-P3Payload $tempSource $policy } 'source-hash'
}
Check 'createnew-no-overwrite' {
    $path=Join-Path $Scratch 'existing.txt'; [IO.File]::WriteAllText($path,'keep')
    Refuses { Copy-P3CreateNew (Join-Path $source 'tx-select-bdf.txt') $path } 'Exception'
    Require ([IO.File]::ReadAllText($path) -eq 'keep')
}
Check 'synthetic-copy-and-final-hashes' {
    $dest=Join-Path $Scratch 'destination'; [IO.Directory]::CreateDirectory($dest) | Out-Null
    $r=@{steps=(New-Object 'System.Collections.Generic.List[object]')}
    Copy-P3Payload $source $dest $policy.payload_files $r
    Require ($r.steps.Count -eq 12 -and $r.steps[11].path -eq 'EFI/BOOT/BOOTX64.EFI')
    foreach ($e in $policy.payload_files) { Require ((Get-FileHash -LiteralPath (Join-Path $dest $e.path)).Hash -ieq $e.sha256) }
    Refuses { Copy-P3Payload $source $dest $policy.payload_files $r } 'destination-no-longer-empty'
}
Check 'copy-svi-only-root-and-metadata-untouched' {
    $dest=Join-Path $Scratch 'svi-destination'; $svi=Join-Path $dest 'System Volume Information'
    [IO.Directory]::CreateDirectory($svi) | Out-Null
    $metadata=Join-Path $svi 'mock-windows-metadata'; [IO.File]::WriteAllText($metadata,'keep')
    $r=@{steps=(New-Object 'System.Collections.Generic.List[object]')}
    Copy-P3Payload $source $dest $policy.payload_files $r
    Require ($r.steps.Count -eq 12 -and [IO.File]::ReadAllText($metadata) -eq 'keep')
}
Check 'copy-svi-named-file-stops' {
    $dest=Join-Path $Scratch 'svi-file'; [IO.Directory]::CreateDirectory($dest) | Out-Null
    [IO.File]::WriteAllText((Join-Path $dest 'System Volume Information'),'keep')
    $r=@{steps=(New-Object 'System.Collections.Generic.List[object]')}
    Refuses { Copy-P3Payload $source $dest $policy.payload_files $r } 'destination-no-longer-empty'
    Require ($r.steps.Count -eq 0)
}
Check 'copy-svi-with-marker-stops-before-write' {
    $dest=Join-Path $Scratch 'svi-marker'; [IO.Directory]::CreateDirectory((Join-Path $dest 'System Volume Information')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $dest 'tx-force-continue.txt'),'')
    $r=@{steps=(New-Object 'System.Collections.Generic.List[object]')}
    Refuses { Copy-P3Payload $source $dest $policy.payload_files $r } 'destination-no-longer-empty'
    Require ($r.steps.Count -eq 0)
}
$originalCopy = ${function:Copy-P3CreateNew}
Check 'partial-failure-stops-with-steps' {
    $dest=Join-Path $Scratch 'partial'; [IO.Directory]::CreateDirectory($dest) | Out-Null
    $r=@{steps=(New-Object 'System.Collections.Generic.List[object]')}; $script:copies=0
    function Copy-P3CreateNew($Source,$Destination) { $script:copies++; if ($script:copies -eq 2) { throw 'injected disk failure' }; & $originalCopy $Source $Destination }
    try {
        Refuses { Copy-P3Payload $source $dest $policy.payload_files $r } 'injected disk failure'
        Require ($r.steps.Count -eq 2 -and $r.steps[0].status -eq 'verified' -and $r.steps[1].status -eq 'copy-attempted')
        Require (-not (Test-Path -LiteralPath (Join-Path $dest 'EFI/BOOT/BOOTX64.EFI')))
    } finally { Set-Item Function:Copy-P3CreateNew $originalCopy }
}
Check 'corrupt-readback-stops' {
    $dest=Join-Path $Scratch 'corrupt'; [IO.Directory]::CreateDirectory($dest) | Out-Null
    $r=@{steps=(New-Object 'System.Collections.Generic.List[object]')}
    function Copy-P3CreateNew($Source,$Destination) { & $originalCopy $Source $Destination; [IO.File]::AppendAllText($Destination,'corrupt') }
    try { Refuses { Copy-P3Payload $source $dest $policy.payload_files $r } 'readback-hash-mismatch'; Require ($r.steps.Count -eq 1) }
    finally { Set-Item Function:Copy-P3CreateNew $originalCopy }
}
Check 'ps-parsefile-all' {
    foreach ($name in @('P3-Common.ps1','Inspect-P3Usb.ps1','Prepare-P3Usb.ps1','Collect-P3Return.ps1')) {
        $tokens=$null; $errors=$null
        [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root ('scripts/'+$name)),[ref]$tokens,[ref]$errors) | Out-Null
        if ($errors.Count) { throw ($errors | Out-String) }
    }
}
$results.ToArray() | ConvertTo-Json -Depth 6 -Compress

if (@($results | Where-Object { -not $_.passed }).Count) { exit 1 }
exit 0
