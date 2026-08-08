# =====================================================
# windows-unit.ps1 — Unit-тесты Windows-модулей (lib/*.ps1)
# Запускается локально (pwsh) и в CI на Windows PowerShell 5.1.
# Выход: exit 0 при успехе, exit 1 при любом падении.
# =====================================================

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'lib\ps-test.ps1')

Write-Host "=== Загрузка модулей ==="
. (Join-Path $root 'lib\detect_hw.ps1')
. (Join-Path $root 'lib\common.ps1')

Write-Host "=== Detect-Hardware (fallback-безопасность) ==="
Detect-Hardware
Assert-True ($null -ne $HW_CPU_VENDOR) 'HW_CPU_VENDOR определён'
Assert-True ($HW_CPU_VIRT_CORES -ge 1) 'HW_CPU_VIRT_CORES >= 1'
Assert-True ($HW_RAM_TOTAL_MB -ge 0) 'HW_RAM_TOTAL_MB >= 0'

Write-Host "=== Get-ModelSizeMB (паритет с bash-факторами) ==="
Assert-Equal 4014 (Get-ModelSizeMB -Filename 'qwen2.5-7b-instruct-q4_k_m.gguf') 'qwen2.5-7b Q4_K_M'
Assert-Equal 7004 (Get-ModelSizeMB -Filename 'gemma-4-12B-it-qat-UD-Q4_K_XL.gguf') 'gemma-4-12B Q4_K_XL'
Assert-Equal 19661 (Get-ModelSizeMB -Filename 'qwen2.5-32B-instruct-q4_k_l.gguf') 'qwen2.5-32B Q4_K_L'
Assert-Equal 1966 (Get-ModelSizeMB -Filename 'test-q3_k_m-3b.gguf') '3B Q3_K_M'
Assert-Equal 6451 (Get-ModelSizeMB -Filename 'test-f16-3b.gguf') '3B F16'
Assert-Equal 3686 (Get-ModelSizeMB -Filename 'test-q8_0-3b.gguf') '3B Q8_0'
Assert-Equal 2212 (Get-ModelSizeMB -Filename 'test-q5_k_s-3b.gguf') '3B Q5_K_S'
Assert-Equal 1690 (Get-ModelSizeMB -Filename 'test-q4_0-3b.gguf') '3B Q4_0'
Assert-Equal 717 (Get-ModelSizeMB -Filename 'test-1b.gguf') '1B без квантизации'

Write-Host "=== Estimate-Context / Estimate-NGL ==="
Assert-Equal 8192 (Estimate-Context -VRAMMB 4096 -RAMMB 1000) 'Context: VRAM>=4096'
Assert-Equal 4096 (Estimate-Context -VRAMMB 0 -RAMMB 16000) 'Context: RAM>=16G'
Assert-Equal 2048 (Estimate-Context -VRAMMB 0 -RAMMB 8000) 'Context: RAM<16G'
Assert-Equal 1 (Estimate-NGL -VRAMMB 0 -ModelMB 4014) 'NGL: без VRAM'
Assert-Equal 52 (Estimate-NGL -VRAMMB 8192 -ModelMB 4014) 'NGL: 8G VRAM / 4G модель'
Assert-Equal 99 (Estimate-NGL -VRAMMB 8192 -ModelMB 100) 'NGL: кап 99'

Write-Host "=== MoE ==="
Assert-True (Test-MOEModel 'mixtral-8x7b-instruct-q4_k_m.gguf') 'MoE: Mixtral-8x7B'
Assert-True (Test-MOEModel 'deepseek-v2-lite-16b-moe-q4_k_m.gguf') 'MoE: DeepSeek-V2'
Assert-True (-not (Test-MOEModel 'qwen2.5-7b-instruct-q4_k_m.gguf')) 'MoE: qwen2.5 не MoE'
Assert-Equal 8 (Get-MOEExpertCount 'mixtral-8x7b-instruct-q4_k_m.gguf') 'MoE: 8 экспертов'
Assert-Equal 64 (Get-MOEExpertCount 'deepseek-v2-lite-16b-moe-q4_k_m.gguf') 'MoE: DeepSeek 64'
Assert-Equal 32 (Get-MOENGL -VRAMMB 8192 -ModelMB 1404 -Experts 8) 'MoE NGL: кап 32'

Write-Host "=== Find-FreePort ==="
$port = Find-FreePort 8080
Assert-True ($port -ge 8080) "Find-FreePort: $port"

Write-Host "=== Run-With-CrashLog (запуск без deadlock, краш-детект) ==="
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("llm_rwcl_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmpDir | Out-Null
try {
    if ($env:OS -eq 'Windows_NT') {
        $binPath = $env:COMSPEC
        $argsExit5 = @('/c', 'exit 5')
        $argsExit0 = @('/c', 'exit 0')
    } else {
        # Start-Process на Linux не квотит составные -c команды — используем скрипты
        Set-Content -Path (Join-Path $tmpDir 'exit5.sh') -Value "#!/bin/sh`nexit 5`n" -Encoding ascii
        Set-Content -Path (Join-Path $tmpDir 'exit0.sh') -Value "#!/bin/sh`nexit 0`n" -Encoding ascii
        $binPath = '/bin/sh'
        $argsExit5 = @((Join-Path $tmpDir 'exit5.sh'))
        $argsExit0 = @((Join-Path $tmpDir 'exit0.sh'))
    }
    $code = Run-With-CrashLog -Mode 'TEST_CRASH' -Backend 'cpu' -BinPath $binPath -CmdArgs $argsExit5
    Assert-Equal 5 $code 'Run-With-CrashLog: exit 5'
    $crashFiles = Get-ChildItem (Join-Path $root 'logs') -Filter 'crash_*_TEST_CRASH.log' -ErrorAction SilentlyContinue
    Assert-Equal 1 @($crashFiles).Count 'Run-With-CrashLog: краш-отчёт создан'
    $code0 = Run-With-CrashLog -Mode 'TEST_OK' -Backend 'cpu' -BinPath $binPath -CmdArgs $argsExit0
    Assert-Equal 0 $code0 'Run-With-CrashLog: exit 0'
    $okFiles = Get-ChildItem (Join-Path $root 'logs') -Filter 'crash_*_TEST_OK.log' -ErrorAction SilentlyContinue
    Assert-Equal 0 @($okFiles).Count 'Run-With-CrashLog: нет отчёта при exit 0'
} finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    Get-ChildItem (Join-Path $root 'logs') -Filter 'crash_*_TEST*.log' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Host "=== New-CrashReport ==="
New-CrashReport -Mode 'TEST' -Backend 'vulkan' -Model 'qwen2.5-7b-instruct-q4_k_m.gguf' -Params 'ctx=2048 ngl=5' -ExitCode 139
$repFiles = Get-ChildItem (Join-Path $root 'logs') -Filter 'crash_*_TEST.log' -ErrorAction SilentlyContinue
Assert-Equal 1 @($repFiles).Count 'New-CrashReport: файл создан'
Get-ChildItem (Join-Path $root 'logs') -Filter 'crash_*_TEST.log' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "=== autotune.ps1: вывод KEY=VALUE ==="
$ps = if ($env:OS -eq 'Windows_NT') { (Get-Command powershell.exe).Source } else { (Get-Command pwsh).Source }
$lines = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'lib\autotune.ps1') -Model 'qwen2.5-7b-instruct-q4_k_m.gguf' -Backend 'cpu' -ModelDir (Join-Path $root 'models') -VramMB 0 -RamMB 8000
$vars = @{}
foreach ($line in $lines) {
    if ($line -match '^([^=]+)=(.+)$') { $vars[$matches[1]] = $matches[2] }
}
Assert-Equal '2048' $vars['LLM_CTX'] 'autotune: LLM_CTX'
Assert-Equal '4014' $vars['LLM_MODEL_MB'] 'autotune: LLM_MODEL_MB'
Assert-Equal '0' $vars['LLM_NGL'] 'autotune: LLM_NGL (cpu)'
Assert-Equal '256' $vars['LLM_BATCH'] 'autotune: LLM_BATCH (cpu)'
Assert-Equal '512' $vars['LLM_UB'] 'autotune: LLM_UB'
Assert-Equal 'False' $vars['LLM_MOE'] 'autotune: LLM_MOE (cpu)'
Assert-True ($vars['LLM_THREADS'] -ge 1) 'autotune: LLM_THREADS'

Write-Host "=== cmd for /f парсинг autotune (только Windows) ==="
if ($env:OS -eq 'Windows_NT') {
    $cmdOut = & cmd /d /c 'for /f "usebackq delims=" %a in (`powershell -NoProfile -ExecutionPolicy Bypass -File lib\autotune.ps1 -Model qwen2.5-7b-instruct-q4_k_m.gguf -Backend cpu -ModelDir models -VramMB 0 -RamMB 8000`) do @echo %a'
    Assert-True ($cmdOut -match 'LLM_CTX=2048') 'cmd for /f: LLM_CTX'
    Assert-True ($cmdOut -match 'LLM_MODEL_MB=4014') 'cmd for /f: LLM_MODEL_MB'
} else {
    Write-Host "SKIP: cmd недоступен на Linux"
}

Write-Host "=== lib/versions.inc (единый источник версий) ==="
$inc = Get-Content (Join-Path $root 'lib\versions.inc') -ErrorAction SilentlyContinue
$llamaV = ($inc | Where-Object { $_ -match '^\s*LLAMA_VERSION=(.+)$' } | Select-Object -First 1)
$whisperV = ($inc | Where-Object { $_ -match '^\s*WHISPER_VERSION=(.+)$' } | Select-Object -First 1)
Assert-True ($null -ne $llamaV -and $llamaV -match '=\S') 'versions.inc: LLAMA_VERSION задана'
Assert-True ($null -ne $whisperV -and $whisperV -match '=\S') 'versions.inc: WHISPER_VERSION задана'

Write-Host "=== Windows.bat: чистый cmd-скрипт (без PS-обёртки) ==="
$bat = Get-Content (Join-Path $root 'Windows.bat') -Raw
Assert-True ($bat -match 'goto main_menu') 'Windows.bat: cmd-скрипт (goto main_menu)'
Assert-True ($bat -match 'autotune.ps1') 'Windows.bat: содержит автотюн'
Assert-True ($bat -match 'Find-FreePort') 'Windows.bat: содержит свободные порты'
Assert-True ($bat -match 'New-CrashReport') 'Windows.bat: содержит краш-логи'
Assert-True ($bat -match 'start /b "" cmd /c "ping') 'Windows.bat: содержит автобраузер'
Assert-True ($bat -match 'versions.inc') 'Windows.bat: читает версии из lib\versions.inc'
$hsOpen = '$content = @' + [char]39
Assert-True (($bat -notmatch [regex]::Escape($hsOpen)) -and ($bat -notmatch 'WriteAllText')) 'Windows.bat: PS-обёртка удалена'

Exit-Tests
