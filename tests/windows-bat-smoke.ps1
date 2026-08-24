# =====================================================
# windows-bat-smoke.ps1 — smoke-тест файла Windows.bat
# Проверяет целостность и связанность batch-скрипта
# без запуска интерактивных меню:
#   * Windows.bat в UTF-8 с BOM (иначе PS 5.1 ломается);
#   * версии читаются из единого источника lib\versions.inc
#     (findstr parses, fallback не «протух»);
#   * каждый lib\*.ps1, на который ссылается bat, существует;
#   * каждый подкаталог bin\... / whisper\bin\, фигурирующий
#     в bat, соответствует путям из lib (detect/autotune);
#   * URL загрузки собраны из %LLAMA_VERSION%/%WHISPER_VERSION%.
# Запуск: pwsh -f tests/windows-bat-smoke.ps1  (exit 0 при успехе)
# Работает и на Linux (pwsh) — не требует Windows.
# =====================================================
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'lib\ps-test.ps1')

$bat = Join-Path $root 'Windows.bat'
$verInc = Join-Path $root 'lib\versions.inc'

Write-Host "=== Windows.bat: BOM и кодировка ==="
$bytes = [System.IO.File]::ReadAllBytes($bat)
Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'BOM (EF BB BF) present'

Write-Host "=== Windows.bat: версии из versions.inc ==="
Assert-True (Test-Path $verInc) 'lib\versions.inc существует'
$incLines = Get-ContentClean $verInc
$llamaLine = $incLines | Where-Object { $_ -match '^LLAMA_VERSION=' } | Select-Object -First 1
$whisperLine = $incLines | Where-Object { $_ -match '^WHISPER_VERSION=' } | Select-Object -First 1
$llamaVer = ($llamaLine -split '=',2)[1].Trim()
$whisperVer = ($whisperLine -split '=',2)[1].Trim()
Assert-True ([bool]$llamaVer -and [bool]$whisperVer) "versions.inc: LLAMA_VERSION='$llamaVer' WHISPER_VERSION='$whisperVer'"

$batLines = Get-ContentClean $bat
# bat должен ссылаться на единый источник версий
Assert-True (($batLines | Where-Object { $_ -match 'versions\.inc' }) -ne $null) 'Windows.bat ссылается на lib\versions.inc'

Write-Host "=== Windows.bat: все упомянутые lib\*.ps1 существуют ==="
foreach ($ps1 in @('lib\detect_hw.ps1','lib\common.ps1','lib\autotune.ps1','lib\update_opencode.ps1')) {
    Assert-True (Test-Path (Join-Path $root $ps1)) "$ps1 существует"
}
Assert-True (Test-Path (Join-Path $root 'lib\update_opencode.ps1')) 'lib\update_opencode.ps1 (для opencode.json)'

Write-Host "=== Windows.bat: структура каталогов bin/ вин-д ==="
# В bat для LLM существуют win-cpu и win-vulkan, для whisper — win-cpu
$cpuRef = $batLines | Where-Object { $_ -match 'bin\\win-cpu\\llama-server\.exe' }
$vkRef  = $batLines | Where-Object { $_ -match 'bin\\win-vulkan\\llama-server\.exe' }
$whRef  = $batLines | Where-Object { $_ -match 'whisper(\\bin)?\\win-cpu\\whisper-server\.exe' }
Assert-True ($cpuRef -ne $null) 'batch использует bin\win-cpu\llama-server.exe'
Assert-True ($vkRef  -ne $null) 'batch использует bin\win-vulkan\llama-server.exe'
Assert-True ($whRef  -ne $null) 'batch использует whisper\bin\win-cpu\whisper-server.exe'

Write-Host "=== Windows.bat: URL загрузки собраны из versions.inc ==="
# bat задаёт LLAMA_URL_BASE/WHISPER_URL_BASE из %LLAMA_VERSION%/%WHISPER_VERSION%,
# а затем дописывает имя файла — проверяем обе части
Assert-True ($batLines -match 'LLAMA_URL_BASE=https://github\.com/ggml-org/llama\.cpp/releases/download/%LLAMA_VERSION%') 'LLAMA_URL_BASE из %LLAMA_VERSION%'
Assert-True ($batLines -match 'WHISPER_URL_BASE=https://github\.com/ggml-org/whisper\.cpp/releases/download/%WHISPER_VERSION%') 'WHISPER_URL_BASE из %WHISPER_VERSION%'
Assert-True ($batLines -match 'llama-%LLAMA_VERSION%-bin-win-cpu-x64\.zip')   'CPU-URL: имя файла llama-%LLAMA_VERSION%-bin-win-cpu-x64.zip'
Assert-True ($batLines -match 'llama-%LLAMA_VERSION%-bin-win-vulkan-x64\.zip') 'Vulkan-URL: llama-%LLAMA_VERSION%-bin-win-vulkan-x64.zip'
Assert-True ($batLines -match 'whisper-bin-x64\.zip') 'Whisper-URL: whisper-bin-x64.zip'

Write-Host "=== Windows.bat: fallback-версии отсутствуют (единый источник versions.inc) ==="
# Фолбэки удалены — версии берутся ТОЛЬКО из lib\versions.inc.
# Убеждаемся, что строк `if not defined LLAMA_VERSION set` и
# `if not defined WHISPER_VERSION set` больше нет.
$fbLlama  = ($batLines | Where-Object { $_ -match 'if not defined LLAMA_VERSION' })
$fbWhisper = ($batLines | Where-Object { $_ -match 'if not defined WHISPER_VERSION' })
Assert-True ($fbLlama.Count -eq 0) "fallback LLAMA_VERSION больше нет в Windows.bat (единый источник versions.inc)"
Assert-True ($fbWhisper.Count -eq 0) "fallback WHISPER_VERSION больше нет в Windows.bat (единый источник versions.inc)"

Exit-Tests