# =====================================================
# update_opencode.ps1 — updates provider "llama-local" in
# the project's opencode.json with the currently loaded
# model id and its port. Uses only built-in PowerShell
# (works on a fresh Windows, no extra dependencies).
#
# Usage: powershell -File update_opencode.ps1 -Model <id> -Port <port>
# =====================================================

param(
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][int]$Port
)

$ErrorActionPreference = 'Stop'

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$configPath = Join-Path $projectDir 'opencode.json'

# Set a property, adding it to the object if it does not exist yet.
function Set-Prop {
    param($obj, [string]$name, $value)
    if ($obj.PSObject.Properties[$name]) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
}

# --- Load existing config, or start from a fresh one ---
$config = $null
if (Test-Path $configPath) {
    try { $config = Get-Content $configPath -Raw | ConvertFrom-Json }
    catch {
        Write-Host "[opencode][!] Не удалось прочитать $configPath (битый JSON). Файл не тронут." -ForegroundColor Yellow
        exit 0
    }
}
if ($null -eq $config) {
    $config = [PSCustomObject]@{ '$schema' = 'https://opencode.ai/config.json' }
}

# --- Ensure provider.llama-local exists ---
if (-not $config.PSObject.Properties['provider']) {
    $config | Add-Member -NotePropertyName 'provider' -NotePropertyValue ([PSCustomObject]@{}) -Force
}
if (-not $config.provider.PSObject.Properties['llama-local']) {
    $config.provider | Add-Member -NotePropertyName 'llama-local' -NotePropertyValue ([PSCustomObject]@{}) -Force
}

# --- Write the current model + port ---
$p = $config.provider.'llama-local'
Set-Prop $p 'npm' '@ai-sdk/openai-compatible'
Set-Prop $p 'name' 'llama.cpp (local)'
Set-Prop $p 'options' @{ baseURL = "http://127.0.0.1:$Port/v1" }
$models = @{}
$models[$Model] = @{ name = $Model }
Set-Prop $p 'models' $models

# --- Serialize (pretty) and save as UTF-8 without BOM ---
$json = $config | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "[opencode] обновлён $configPath (model=$Model, port=$Port)"