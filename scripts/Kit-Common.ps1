# Importing this file defines functions only. Compatible with Windows PowerShell 5.1.
function Get-KitRoot { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
function Resolve-KitPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'missing-or-empty-path' }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    [IO.Path]::GetFullPath((Join-Path (Get-KitRoot) $Path))
}
function Read-KitEnvironment([string]$Path, [bool]$IsExplicit = $false) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ($IsExplicit) { throw 'missing-or-empty-setting: config' }
        $Path = Join-Path (Get-KitRoot) 'config/environment.local.json'
        if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{} }
    }
    $value = Get-Content -LiteralPath (Resolve-KitPath $Path) -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $value -or $value -is [array] -or $value -is [string] -or $value -is [ValueType]) { throw 'configuration-object-required' }
    $value
}
function Resolve-KitSetting($Data, [string]$Name, $Explicit, [bool]$IsExplicit, $Default = $null) {
    $value = if ($IsExplicit) { $Explicit } elseif ($null -ne $Data.PSObject.Properties[$Name]) { $Data.$Name } else { $Default }
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) { throw ('missing-or-empty-setting: ' + $Name) }
    $value
}
function Assert-KitGpu($Gpu) {
    if ($null -eq $Gpu -or $Gpu.uuid -notmatch '^GPU-[0-9a-f-]+$' -or $Gpu.subsystem_id -notmatch '^[0-9a-f]{8}$') { throw 'explicit-gpu-target-required' }
    $pattern = '^PCI\\VEN_10DE&DEV_1E04&SUBSYS_' + [regex]::Escape($Gpu.subsystem_id) + '(?:&REV_[0-9A-F]{2})?\\[^\\]+$'
    if ($Gpu.pnp_instance_id -notmatch $pattern) { throw 'gpu-pnp-identity-mismatch' }
}
function Resolve-KitGpu($Environment, [string]$GpuJson, [bool]$IsExplicit) {
    $gpu = if ($IsExplicit) { $GpuJson | ConvertFrom-Json -ErrorAction Stop } else { $Environment.gpu }
    Assert-KitGpu $gpu
    $gpu
}
function Assert-KitConfirmation([string]$Expected, [string]$Provided, [bool]$IsExplicit) {
    Write-Host ('Target confirmation required: ' + $Expected)
    $answer = if ($IsExplicit) { $Provided } else { Read-Host 'Type the complete confirmation above' }
    if ($answer -cne $Expected) { throw 'explicit-confirmation-mismatch' }
}
