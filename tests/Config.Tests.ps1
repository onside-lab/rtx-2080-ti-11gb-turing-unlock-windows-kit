param([string]$Root)
$ErrorActionPreference='Stop'
. (Join-Path $Root 'scripts/Kit-Common.ps1')
function Require($Value) { if (-not $Value) { throw 'assertion failed' } }
function Refuses([scriptblock]$Body) { $failed=$false; try { & $Body | Out-Null } catch { $failed=$true }; Require $failed }
$data=[pscustomobject]@{value='json';empty='';gpu=$null}
Require ((Resolve-KitSetting $data 'value' 'argument' $true 'default') -eq 'argument')
Require ((Resolve-KitSetting $data 'value' $null $false 'default') -eq 'json')
Require ((Resolve-KitSetting $data 'missing' $null $false 'default') -eq 'default')
Refuses { Resolve-KitSetting $data 'value' '' $true 'default' }
Refuses { Resolve-KitSetting $data 'empty' $null $false 'default' }
Refuses { Resolve-KitSetting $data 'missing' $null $false }
Refuses { Resolve-KitGpu $data '' $false }
Refuses { Read-KitEnvironment '' $true }
Refuses { Assert-KitConfirmation 'required' 'different' $true }
Assert-KitConfirmation 'required' 'required' $true
@{passed=$true;checks=10} | ConvertTo-Json -Compress
