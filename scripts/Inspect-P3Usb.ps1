[CmdletBinding()]
param([string]$Config, [string]$Reports, [string]$MediaPolicy)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Kit-Common.ps1')
. (Join-Path $PSScriptRoot 'P3-Common.ps1')
$code = 2
try {
    $environment = Read-KitEnvironment $Config ($PSBoundParameters.ContainsKey('Config'))
    $reportsPath = Resolve-KitPath (Resolve-KitSetting $environment 'reports_dir' $Reports ($PSBoundParameters.ContainsKey('Reports')) 'reports')
    $media = Read-P3Json (Resolve-KitPath (Resolve-KitSetting $environment 'media_policy' $MediaPolicy ($PSBoundParameters.ContainsKey('MediaPolicy'))))
    $inventory = Get-P3Inventory (Get-KitRoot)
    $selection = Get-P3Selection $inventory $media $null (Get-KitRoot)
    $report = [ordered]@{schema_version=1; status=$selection.status; read_only=$true; inventory=$inventory; selection=$selection; reason=$selection.reason}
    if ($selection.status -eq 'identified') {
        $report['identity_sha256'] = $selection.candidates[0].identity_sha256
        $report['binding_sha256'] = Get-P3Binding $selection.candidates[0]
        $code = 0
    } else { $code = 1 }
    [IO.Directory]::CreateDirectory($reportsPath) | Out-Null
    $path = Join-Path $reportsPath ('p3-usb-inspect-' + (Get-P3Stamp) + '.json')
    Write-P3Json $path $report
    Write-Host $path
    Write-Host 'Review the inventory and pin identity, binding, Volume GUID, report path and report hash in a local policy before copying.'
} catch { [Console]::Error.WriteLine($_.Exception.Message); $code = 2 }
exit $code
