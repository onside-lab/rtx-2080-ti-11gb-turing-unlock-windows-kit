param([string]$Root, [ValidateSet('RootPaths')][string]$Mode = 'RootPaths')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. (Join-Path $Root 'scripts/P3-Common.ps1')
function Require($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$policy = Read-P3Json (Join-Path $Root 'config/p3-usb-policy.example.json')
if ($Mode -eq 'RootPaths') {
    # Pure calculation only: never pass the volume root to any filesystem operation.
    $guidRoot = '\\?\Volume{11111111-2222-3333-4444-555555555555}\'
    foreach ($entry in $policy.payload_files) {
        foreach ($relative in @($entry.path, $entry.path.Replace('/','\'))) {
            $paths = Get-P3PayloadPaths $guidRoot $relative
            Require ($paths.destination_root -ceq $guidRoot) 'Volume root lost its trailing separator'
            Require ($paths.target -ceq ($guidRoot + $entry.path.Replace('/','\'))) 'Wrong target path'
            if ($entry.path -eq 'EFI/BOOT/BOOTX64.EFI') {
                Require ($paths.parent -ceq ($guidRoot + 'EFI\BOOT')) 'Wrong EFI parent'
                Require (($paths.directories -join '|') -ceq (($guidRoot + 'EFI') + '|' + ($guidRoot + 'EFI\BOOT'))) 'Wrong directory creation plan'
            } else {
                Require ($paths.parent -ceq $guidRoot) 'Root file parent lost its trailing separator'
                Require (@($paths.directories).Count -eq 0) 'Root file must not create a directory'
            }
        }
    }
    # Existing directory destinations without a trailing separator remain supported.
    $paths = Get-P3PayloadPaths (Join-Path $env:SystemDrive 'synthetic-path-only') 'EFI/BOOT/BOOTX64.EFI'
    Require ($paths.target -ceq ((Join-Path $env:SystemDrive 'synthetic-path-only') + '\EFI\BOOT\BOOTX64.EFI')) 'Wrong temporary target'
    $stamps = @(1..100 | ForEach-Object { Get-P3Stamp })
    Require (@($stamps | Sort-Object -Unique).Count -eq 100) 'Receipt names collided'
    Assert-P3Empty ([pscustomobject]@{file_system='FAT32';root_listing_error=$null;allocation_unit_bytes=4096;
        root_entries=@([pscustomobject]@{name='System Volume Information';directory=$true;attributes='Hidden, System, Directory'})})
    @{mode=$Mode; passed=$true; payload_paths=12; root_files_without_directory_creation=11; receipt_names_unique=100} | ConvertTo-Json -Compress
    exit 0
}
