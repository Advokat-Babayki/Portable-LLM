# =====================================================
# windows-bat-cli.ps1 — Тест CLI-парсинга Windows.bat
# Проверяет:
#   * for /f парсинг вывода autotune.ps1 (KEY=VALUE → set)
#   * корректное чтение версий из lib\versions.inc
#   * Детерминированный вызов autotune с синтетическим GGUF
#   * Проверка LLM_MOE и LLM_EXPERTS из autotune
# Запуск: pwsh -f tests/windows-bat-cli.ps1  (exit 0 при успехе)
# Работает и на Linux (pwsh) — не требует Windows.
# =====================================================
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'lib\ps-test.ps1')

$bat = Join-Path $root 'Windows.bat'
$verInc = Join-Path $root 'lib\versions.inc'

Write-Host "=== Windows.bat CLI: чтение версий из versions.inc ==="
Assert-True (Test-Path $verInc) 'lib\versions.inc существует'
$incLines = Get-ContentClean $verInc
$llamaLine = ($incLines | Where-Object { $_ -match '^LLAMA_VERSION=' } | Select-Object -First 1)
$whisperLine = ($incLines | Where-Object { $_ -match '^WHISPER_VERSION=' } | Select-Object -First 1)
$llamaVer = ($llamaLine -split '=',2)[1].Trim()
$whisperVer = ($whisperLine -split '=',2)[1].Trim()
Assert-True ([bool]$llamaVer -and [bool]$whisperVer) "versions.inc: LLAMA_VERSION='$llamaVer' WHISPER_VERSION='$whisperVer'"

Write-Host "=== Windows.bat CLI: проверка парсинга for /f (KEY=VALUE формат) ==="
# В Windows.bat используется:
#   for /f "usebackq delims=" %%a in (`powershell -NoProfile ... autotune.ps1 ...`) do set "%%a"
# Проверяем, что каждая строка вывода autotune — валидный KEY=VALUE
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('llm_clitest_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmpDir -Force | Out-Null
try {
    # Синтетический GGUF для детерминизма (тот же base64, что в linux-unit.sh)
    $ggufB64 = 'R0dVRgMAAAAMAAAAAAAAAAcAAAAAAAAAFAAAAAAAAABnZW5lcmFsLmFyY2hpdGVjdHVyZQgAAAAFAAAAAAAAAHF3ZW4yFAAAAAAAAABxd2VuMi5jb250ZXh0X2xlbmd0aAQAAAAAgAAAFgAAAAAAAABxd2VuMi5lbWJlZGRpbmdfbGVuZ3RoBAAAAAAOAAARAAAAAAAAAHF3ZW4yLmJsb2NrX2NvdW50BAAAABwAAAAaAAAAAAAAAHF3ZW4yLmF0dGVudGlvbi5oZWFkX2NvdW50BAAAABwAAAAdAAAAAAAAAHF3ZW4yLmF0dGVudGlvbi5oZWFkX2NvdW50X2t2BAAAAAQAAAAYAAAAAAAAAHF3ZW4yLmF0dGVudGlvbi5oZWFkX2RpbQQAAACAAAAAEAAAAAAAAABxd2VuMi52b2NhYl9zaXplBAAAAIBRAgAVAAAAAAAAAHRva2VuaXplci5nZ21sLnRva2VucwkAAAAIAAAAAwAAAAAAAAAFAAAAAAAAAGhlbGxvBQAAAAAAAAB3b3JsZAEAAAAAAAAAIQ=='
    $synthModel = Join-Path $tmpDir 'qwen2.5-7b-instruct-q4_k_m.gguf'
    [System.IO.File]::WriteAllBytes($synthModel, [Convert]::FromBase64String($ggufB64))
    
    # Запуск autotune.ps1 через pwsh напрямую (как это делает Windows.bat через for /f)
    $psExe = if ($env:OS -eq 'Windows_NT') { (Get-Command powershell.exe).Source } else { (Get-Command pwsh).Source }
    $autotuneLines = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'lib\autotune.ps1') -Model 'qwen2.5-7b-instruct-q4_k_m.gguf' -Backend 'cpu' -ModelDir $tmpDir -VramMB 0 -RamMB 8000
    
    # Проверка, что каждая строка — KEY=VALUE
    $lineCount = 0
    foreach ($line in $autotuneLines) {
        Assert-True ($line -match '^[A-Z_]+=.+$') "autotune CLI: строка '$line' — формат KEY=VALUE"
        $lineCount++
    }
    Assert-True ($lineCount -ge 4) "autotune CLI: минимум 4 строки вывода (получено $lineCount)"
    
    # Проверка конкретных значений
    $vars = @{}
    foreach ($line in $autotuneLines) {
        if ($line -match '^([^=]+)=(.+)$') { $vars[$matches[1]] = $matches[2] }
    }
    
    Assert-Equal '32768' $vars['LLM_CTX'] 'autotune CLI: LLM_CTX'
    Assert-Equal '4014' $vars['LLM_MODEL_MB'] 'autotune CLI: LLM_MODEL_MB'
    Assert-Equal '0' $vars['LLM_NGL'] 'autotune CLI: LLM_NGL (cpu)'
    Assert-Equal '256' $vars['LLM_BATCH'] 'autotune CLI: LLM_BATCH (cpu)'
    # LLM_MOE — всегда boolean (True или False)
    Assert-True ($vars['LLM_MOE'] -eq 'True' -or $vars['LLM_MOE'] -eq 'False') "autotune CLI: LLM_MOE — bool ($($vars['LLM_MOE']))"
    Assert-True ($vars['LLM_THREADS'] -ge 1) 'autotune CLI: LLM_THREADS >= 1'
} finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
}

Write-Host "=== Windows.bat CLI: autotune с vulkan backend и MoE-моделью ==="
$tmpDir2 = Join-Path ([System.IO.Path]::GetTempPath()) ('llm_clitest_moe_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmpDir2 -Force | Out-Null
try {
    $fakeMoeModel = Join-Path $tmpDir2 'mixtral-8x7b-instruct-q4_k_m.gguf'
    [System.IO.File]::WriteAllBytes($fakeMoeModel, [Convert]::FromBase64String($ggufB64))
    
    $psExe = if ($env:OS -eq 'Windows_NT') { (Get-Command powershell.exe).Source } else { (Get-Command pwsh).Source }
    $moeLines = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'lib\autotune.ps1') -Model 'mixtral-8x7b-instruct-q4_k_m.gguf' -Backend 'vulkan' -ModelDir $tmpDir2 -VramMB 61440 -RamMB 8000
    
    $moeVars = @{}
    foreach ($line in $moeLines) {
        if ($line -match '^([^=]+)=(.+)$') { $moeVars[$matches[1]] = $matches[2] }
    }
    
    # На Windows с реальным желе: HW_VULKAN_FOUND=true → MoE детектится, LLM_MOE=True
    # На Linux без Vulkan: HW_VULKAN_FOUND=false → MoE проверка не входит, LLM_MOE=False
    # Оба варианта допустимы — проверяем консистентность
    if ($moeVars['LLM_MOE'] -eq 'True') {
        Assert-True ([int]$moeVars['LLM_EXPERTS'] -eq 8) 'autotune vulkan MoE: LLM_EXPERTS=8'
        Assert-True ([int]$moeVars['LLM_NGL'] -le 32) 'autotune vulkan MoE: LLM_NGL <= 32 (cap)'
        Write-Host "INFO: Vulkan/MoE детекция активна (LLM_MOE=True)"
    } else {
        Write-Host "INFO: Vulkan не обнаружен — MoE проверка пропущена (LLM_MOE=False)"
    }
    # LLM_EXPERTS всегда задан (0 если не MoE, >0 если MoE)
    Assert-True ($moeVars.ContainsKey('LLM_EXPERTS')) 'autotune vulkan: LLM_EXPERTS определён'
} finally {
    Remove-Item -Recurse -Force $tmpDir2 -ErrorAction SilentlyContinue
}

# На Windows: тест cmd for /f парсинга autotune (как это делает Windows.bat)
if ($env:OS -eq 'Windows_NT') {
    Write-Host "=== Windows.bat CLI: cmd for /f парсинг (только Windows) ==="
    $tmpDir3 = Join-Path ([System.IO.Path]::GetTempPath()) ('llm_clitest_cmd_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $tmpDir3 -Force | Out-Null
    try {
        $synthModel3 = Join-Path $tmpDir3 'qwen2.5-7b-instruct-q4_k_m.gguf'
        [System.IO.File]::WriteAllBytes($synthModel3, [Convert]::FromBase64String($ggufB64))
        
        # cmd for /f парсинг, как в Windows.bat:
        # Создаём временный .bat-файл, который эмулирует синтаксис Windows.bat
        $batchFile = Join-Path $tmpDir3 'test_parsing.bat'
        $batContent = @"
@echo off
for /f "usebackq delims=" %%%%a in (`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$root\lib\autotune.ps1" -Model qwen2.5-7b-instruct-q4_k_m.gguf -Backend cpu -ModelDir "$tmpDir3" -VramMB 0 -RamMB 8000`) do echo %%%%a
"@
        [System.IO.File]::WriteAllText($batchFile, $batContent)
        $cmdOut = & cmd /d /c "`"$batchFile`""
        
        Assert-True ($cmdOut -match 'LLM_CTX=32768') 'cmd for /f: LLM_CTX из autotune'
        Assert-True ($cmdOut -match 'LLM_MODEL_MB=4014') 'cmd for /f: LLM_MODEL_MB'
        Assert-True ($cmdOut -match 'LLM_MOE=') 'cmd for /f: LLM_MOE определена'
        Assert-True ($cmdOut -match 'LLM_EXPERTS=') 'cmd for /f: LLM_EXPERTS определена'
    } finally {
        Remove-Item -Recurse -Force $tmpDir3 -ErrorAction SilentlyContinue
    }
} else {
    Write-Host "SKIP: cmd for /f тест недоступен на Linux"
}

Exit-Tests