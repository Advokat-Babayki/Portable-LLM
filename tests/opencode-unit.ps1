# =====================================================
# opencode-unit.ps1 — Unit-тесты lib/update_opencode.ps1
# Зеркалит tests/opencode-unit.sh (bash-версию): та же логика
# должна давать одинаковые результаты в обоих рантаймах.
# Работает с $env:USERPROFILE в temp-папке; после каждого шага
# конфиг проверяется как валидный JSON через ConvertFrom-Json.
# Запуск: pwsh tests/opencode-unit.ps1  (exit 0 при успехе)
# =====================================================

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'lib\ps-test.ps1')
$script:work = Join-Path ([System.IO.Path]::GetTempPath()) ("llm_ocu_" + [guid]::NewGuid().ToString('N'))
$update = Join-Path $root 'lib\update_opencode.ps1'

# --- Запуск update_opencode.ps1 в изолированном окружении ---
function Invoke-CfgUpdate {
    param([string]$Test, [string]$Model, [int]$Port)
    $env:USERPROFILE = Join-Path $script:work $Test
    & pwsh -NoProfile -File $update -Model $Model -Port $Port *>$null
}

function Get-CfgPath {
    param([string]$Test, [string]$Ext = 'json')
    Join-Path $script:work "$Test\.config\opencode\opencode.$Ext"
}

function Test-Json {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $null = Get-Content $Path -Raw | ConvertFrom-Json
        return $true
    } catch { return $false }
}

try {
    Write-Host "=== a: создание нового конфига ==="
    Invoke-CfgUpdate -Test a -Model 'qwen2.5-7b-instruct-q4_k_m.gguf' -Port 8081
    $cfgA = Get-CfgPath a
    Assert-True (Test-Json $cfgA) 'a: валидный JSON'
    $j = Get-Content $cfgA -Raw | ConvertFrom-Json
    Assert-Equal 'http://127.0.0.1:8081/v1' $j.provider.'llama-local'.options.baseURL 'a: baseURL=...8081/v1'
    Assert-Equal 'qwen2.5-7b-instruct-q4_k_m.gguf' $j.provider.'llama-local'.models.'qwen2.5-7b-instruct-q4_k_m.gguf'.name 'a: модель записана'

    Write-Host "=== b: обновление существующего (другие поля сохраняются) ==="
    $cfgB = Get-CfgPath b
    New-Item -ItemType Directory -Force (Split-Path $cfgB) | Out-Null
    @'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama-local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (local)",
      "options": { "baseURL": "http://127.0.0.1:8080/v1" },
      "models": { "old.gguf": { "name": "old.gguf" } }
    },
    "anthropic": { "npm": "@ai-sdk/anthropic" },
    "other-key": 1
  },
  "theme": "x"
}
'@ | Set-Content $cfgB -Encoding ascii
    Invoke-CfgUpdate -Test b -Model new.gguf -Port 9090
    Assert-True (Test-Json $cfgB) 'b: валидный JSON после обновления'
    $j = Get-Content $cfgB -Raw | ConvertFrom-Json
    Assert-Equal 'http://127.0.0.1:9090/v1' $j.provider.'llama-local'.options.baseURL 'b: baseURL обновлён'
    Assert-Equal 'new.gguf' $j.provider.'llama-local'.models.'new.gguf'.name 'b: модель заменена'
    Assert-Equal '@ai-sdk/anthropic' $j.provider.anthropic.npm 'b: сторонний провайдер сохранён'
    Assert-Equal 'x' $j.theme 'b: тема сохранена'
    Assert-True (Test-Path "$cfgB.bak") 'b: создан .bak'

    Write-Host "=== c: идемпотентность — .bak один раз, повторный прогон валиден ==="
    Invoke-CfgUpdate -Test b -Model model3.gguf -Port 9191
    $cfgC = Get-CfgPath b
    Assert-True (Test-Json $cfgC) 'c: повторный прогон — валидный JSON'
    Assert-True (-not (Test-Path "$cfgC.bak.bak")) 'c: второй .bak НЕ создан'

    Write-Host "=== d: битый JSON — файл не трогается, exit 0 ==="
    $cfgD = Get-CfgPath d
    New-Item -ItemType Directory -Force (Split-Path $cfgD) | Out-Null
    Set-Content $cfgD '{ "broken": ' -Encoding UTF8
    $bytesBefore = (Get-Item $cfgD).Length
    $env:USERPROFILE = Join-Path $script:work d
    $out = & pwsh -NoProfile -File $update -Model m.gguf -Port 1 2>&1
    $rc = $LASTEXITCODE; if ($null -eq $rc) { $rc = 0 }
    $bytesAfter = (Get-Item $cfgD).Length
    Assert-Equal $bytesBefore $bytesAfter 'd: битый JSON не тронут'
    Assert-True ($rc -le 1) "d: exit 0/1 ($rc)"

    Write-Host "=== e: jsonc имеет приоритет над json ==="
    $cfgE = Get-CfgPath e
    New-Item -ItemType Directory -Force (Split-Path $cfgE) | Out-Null
    Set-Content (Join-Path (Split-Path $cfgE) 'opencode.jsonc') '{"theme":"dark"}' -Encoding UTF8
    Set-Content (Join-Path (Split-Path $cfgE) 'opencode.json') '{"old":"json"}' -Encoding UTF8
    $env:USERPROFILE = Join-Path $script:work 'e'
    & pwsh -NoProfile -File $update -Model 'e.gguf' -Port 7 *>$null
    $jc = (Get-Content (Join-Path (Split-Path $cfgE) 'opencode.jsonc') -Raw | ConvertFrom-Json)
    $jE = (Get-Content (Join-Path (Split-Path $cfgE) 'opencode.json') -Raw | ConvertFrom-Json)
    Assert-Equal 'http://127.0.0.1:7/v1' $jc.provider.'llama-local'.options.baseURL 'e: jsonc обновлён'
    Assert-Equal 'json' $jE.old 'e: json не тронут'

    Write-Host "=== f: существует только jsonc — приоритет jsonc (нет json) ==="
    $cfgF = Get-CfgPath f
    New-Item -ItemType Directory -Force (Split-Path $cfgF) | Out-Null
    Set-Content (Join-Path (Split-Path $cfgF) 'opencode.jsonc') '{"c":"x"}' -Encoding UTF8
    $env:USERPROFILE = Join-Path $script:work 'f'
    & pwsh -NoProfile -File $update -Model 'f.gguf' -Port 4444 *>$null
    $jF = Get-Content (Join-Path (Split-Path $cfgF) 'opencode.jsonc') -Raw | ConvertFrom-Json
    Assert-Equal 'http://127.0.0.1:4444/v1' $jF.provider.'llama-local'.options.baseURL 'f: только jsonc — обновлён jsonc'
    Assert-True (-not (Test-Path $cfgF)) 'f: json не создан'

    Exit-Tests
} finally {
    Remove-Item -Recurse -Force $script:work -ErrorAction SilentlyContinue
    Remove-Item Env:\USERPROFILE -ErrorAction SilentlyContinue
}