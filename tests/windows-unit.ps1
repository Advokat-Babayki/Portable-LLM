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

Write-Host "=== Estimate-Context / Estimate-NGL (fallback-эвристика не менялась) ==="
Assert-Equal 8192 (Estimate-Context -VRAMMB 4096 -RAMMB 1000) 'Context: VRAM>=4096'
Assert-Equal 4096 (Estimate-Context -VRAMMB 0 -RAMMB 16000) 'Context: RAM>=16G'
Assert-Equal 2048 (Estimate-Context -VRAMMB 0 -RAMMB 8000) 'Context: RAM<16G'
Assert-Equal 1 (Estimate-NGL -VRAMMB 0 -ModelMB 4014) 'NGL: без VRAM'
Assert-Equal 52 (Estimate-NGL -VRAMMB 8192 -ModelMB 4014) 'NGL: 8G VRAM / 4G модель'
Assert-Equal 99 (Estimate-NGL -VRAMMB 8192 -ModelMB 100) 'NGL: кап 99'

Write-Host "=== GGUF-парсер (синтетический мини-GGUF, паритет с bash-тестом) ==="
$tmpGguf = Join-Path ([System.IO.Path]::GetTempPath()) ('llm_gguf_test_' + [guid]::NewGuid().ToString('N') + '.gguf')
# Тот же байт-в-байт файл, что в linux-unit.sh (qwen2: 28L/4KV/128hd, ctx 32768)
$ggufB64 = 'R0dVRgMAAAAMAAAAAAAAAAcAAAAAAAAAFAAAAAAAAABnZW5lcmFsLmFyY2hpdGVjdHVyZQgAAAAFAAAAAAAAAHF3ZW4yFAAAAAAAAABxd2VuMi5jb250ZXh0X2xlbmd0aAQAAAAAgAAAFgAAAAAAAABxd2VuMi5lbWJlZGRpbmdfbGVuZ3RoBAAAAAAOAAARAAAAAAAAAHF3ZW4yLmJsb2NrX2NvdW50BAAAABwAAAAaAAAAAAAAAHF3ZW4yLmF0dGVudGlvbi5oZWFkX2NvdW50BAAAABwAAAAdAAAAAAAAAHF3ZW4yLmF0dGVudGlvbi5oZWFkX2NvdW50X2t2BAAAAAQAAAAYAAAAAAAAAHF3ZW4yLmF0dGVudGlvbi5oZWFkX2RpbQQAAACAAAAAEAAAAAAAAABxd2VuMi52b2NhYl9zaXplBAAAAIBRAgAVAAAAAAAAAHRva2VuaXplci5nZ21sLnRva2VucwkAAAAIAAAAAwAAAAAAAAAFAAAAAAAAAGhlbGxvBQAAAAAAAAB3b3JsZAEAAAAAAAAAIQ=='
[System.IO.File]::WriteAllBytes($tmpGguf, [Convert]::FromBase64String($ggufB64))
try {
    $meta = Read-GgufMeta -Path $tmpGguf
    Assert-True ($null -ne $meta) 'GGUF: парсинг успешен'
    Assert-Equal 32768 $meta.Ctx 'GGUF: context_length = 32768'
    Assert-Equal 28 $meta.Layers 'GGUF: block_count = 28'
    Assert-Equal 4 $meta.KVHeads 'GGUF: head_count_kv = 4'
    Assert-Equal 128 $meta.HeadDim 'GGUF: head_dim = 128'

    Write-Host "=== Get-RecommendedContext (паритет с estimate_context_model bash) ==="
    Assert-Equal 13385 (Get-RecommendedContext -ModelFile $tmpGguf -Backend 'cpu' -RAMAvailMB 3000 -ModelMB 1500 -VRAMMB 0) 'Rec-Ctx cpu free3000/model1500'
    Assert-Equal 32768 (Get-RecommendedContext -ModelFile $tmpGguf -Backend 'vulkan' -RAMAvailMB 3000 -ModelMB 1500 -VRAMMB 4096) 'Rec-Ctx vulkan vram4096 native'
    Assert-Equal 32768 (Get-RecommendedContext -ModelFile $tmpGguf -Backend 'cpu' -RAMAvailMB 8192 -ModelMB 4014 -VRAMMB 0) 'Rec-Ctx cpu free8192/model4014'
    Assert-Equal 256 (Get-RecommendedContext -ModelFile $tmpGguf -Backend 'cpu' -RAMAvailMB 4096 -ModelMB 4014 -VRAMMB 0) 'Rec-Ctx cpu min 256'
    Assert-Equal 2048 (Get-RecommendedContext -ModelFile '' -Backend 'cpu' -RAMAvailMB 4096 -ModelMB 1000 -VRAMMB 0) 'Rec-Ctx пустой -> fallback RAM<16G'
    Assert-Equal 8192 (Get-RecommendedContext -ModelFile 'C:\nonexistent.gguf' -Backend 'cpu' -RAMAvailMB 4096 -ModelMB 1000 -VRAMMB 4096) 'Rec-Ctx нет GGUF+VRAM4096 -> fallback VRAM'
} finally {
    Remove-Item -Force $tmpGguf -ErrorAction SilentlyContinue
}

Write-Host "=== GGUF: регрессия раннего выхода (большой tokenizer) ==="
$tmpBigGguf = Join-Path ([System.IO.Path]::GetTempPath()) ('llm_gguf_big_' + [guid]::NewGuid().ToString('N') + '.gguf')
$fsBig = [System.IO.File]::Create($tmpBigGguf)
$wBig = New-Object System.IO.BinaryWriter $fsBig
function Write-W64([long]$v) { $wBig.Write([System.BitConverter]::GetBytes([uint64]$v)) }
function Write-W32([int]$v)  { $wBig.Write([System.BitConverter]::GetBytes([uint32]$v)) }
function Write-BigKey([string]$k) { $kb = [System.Text.Encoding]::UTF8.GetBytes($k); $wBig.Write([System.BitConverter]::GetBytes([uint64]$kb.Length)); $wBig.Write($kb) }
function Write-BigStr([string]$k, [string]$v) { Write-BigKey $k; Write-W32 8; $vb = [System.Text.Encoding]::UTF8.GetBytes($v); $wBig.Write([System.BitConverter]::GetBytes([uint64]$vb.Length)); $wBig.Write($vb) }
function Write-BigU32([string]$k, [int]$v) { Write-BigKey $k; Write-W32 4; Write-W32 $v }
$wBig.Write([System.Text.Encoding]::ASCII.GetBytes('GGUF'))
Write-W32 3; Write-W64 0; Write-W64 7
Write-BigStr 'general.architecture' 'qwen2'
Write-BigU32 'qwen2.block_count' 36
Write-BigU32 'qwen2.context_length' 32768
Write-BigU32 'qwen2.embedding_length' 2048
Write-BigU32 'qwen2.attention.head_count' 16
Write-BigU32 'qwen2.attention.head_count_kv' 2
$tk = [System.Text.Encoding]::UTF8.GetBytes('tokenizer.ggml.tokens')
$wBig.Write([System.BitConverter]::GetBytes([uint64]$tk.Length)); $wBig.Write($tk)
Write-W32 9; Write-W32 8; Write-W64 200000
$wBig.Write((New-Object byte[] (200000 * 8)))
$wBig.Close()
try {
    $metaBig = Read-GgufMeta -Path $tmpBigGguf
    Assert-True ($null -ne $metaBig) 'GGUF-big: парсинг успешен'
    Assert-Equal 32768 $metaBig.Ctx 'GGUF-big: context_length'
    Assert-Equal 36 $metaBig.Layers 'GGUF-big: block_count'
    Assert-Equal 2 $metaBig.KVHeads 'GGUF-big: head_count_kv'
    Assert-Equal 128 $metaBig.HeadDim 'GGUF-big: head_dim (деривация embed/head)'
} finally {
    Remove-Item -Force $tmpBigGguf -ErrorAction SilentlyContinue
}

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
# Детерминизм: на любом железе ModelDir указывает на синтетический GGUF,
# чтобы LLM_CTX не зависел от того, лежит ли реальная модель в models/.
$tmpModelDir = Join-Path ([System.IO.Path]::GetTempPath()) ('llm_autotune_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmpModelDir | Out-Null
$synthModel = Join-Path $tmpModelDir 'qwen2.5-7b-instruct-q4_k_m.gguf'
[System.IO.File]::WriteAllBytes($synthModel, [Convert]::FromBase64String($ggufB64))
$ps = if ($env:OS -eq 'Windows_NT') { (Get-Command powershell.exe).Source } else { (Get-Command pwsh).Source }
$lines = & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'lib\autotune.ps1') -Model 'qwen2.5-7b-instruct-q4_k_m.gguf' -Backend 'cpu' -ModelDir $tmpModelDir -VramMB 0 -RamMB 8000
$vars = @{}
foreach ($line in $lines) {
    if ($line -match '^([^=]+)=(.+)$') { $vars[$matches[1]] = $matches[2] }
}
Assert-Equal '32768' $vars['LLM_CTX'] 'autotune: LLM_CTX (native cap из GGUF)'
Assert-Equal '4014' $vars['LLM_MODEL_MB'] 'autotune: LLM_MODEL_MB'
Assert-Equal '0' $vars['LLM_NGL'] 'autotune: LLM_NGL (cpu)'
Assert-Equal '256' $vars['LLM_BATCH'] 'autotune: LLM_BATCH (cpu)'
Assert-Equal '512' $vars['LLM_UB'] 'autotune: LLM_UB'
Assert-Equal 'False' $vars['LLM_MOE'] 'autotune: LLM_MOE (cpu)'
Assert-True ($vars['LLM_THREADS'] -ge 1) 'autotune: LLM_THREADS'
Remove-Item -Recurse -Force $tmpModelDir -ErrorAction SilentlyContinue

Write-Host "=== cmd for /f парсинг autotune (только Windows) ==="
if ($env:OS -eq 'Windows_NT') {
    # Модели в ModelDir нет → fallback-эвристика (детерминизм на пустом CI)
    $cmdOut = & cmd /d /c 'for /f "usebackq delims=" %a in (`powershell -NoProfile -ExecutionPolicy Bypass -File lib\autotune.ps1 -Model qwen2.5-7b-instruct-q4_k_m.gguf -Backend cpu -ModelDir "" -VramMB 0 -RamMB 8000`) do @echo %a'
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
