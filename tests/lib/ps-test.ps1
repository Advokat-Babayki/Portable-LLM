# =====================================================
# ps-test.ps1 — общая библиотека ассертов для PowerShell-тестов.
# Подключается: . (Join-Path $PSScriptRoot 'lib\ps-test.ps1')
# (dot-source в том же scope — $root и $script:failures наследуются)
#
# Даёт:
#   $root            — корень репозитория (двумя уровнями выше tests\lib)
#   Assert-Equal <Expected> <Actual> <Name>
#   Assert-True <Cond> <Name>
#   Get-ContentClean <Path>   — строки без BOM
#   Exit-Tests                 — вывод итога + exit 0/1
#
# ВАЖНО: файл в UTF-8 с BOM (для Windows PowerShell 5.1 — грабли f9df0aa).
# =====================================================

# Корень репозитория: ...\tests\lib\ps-test.ps1 -> на два уровня вверх
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:failures = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -ne $Actual) {
        $script:failures++
        Write-Host "FAIL: $Name — ожидал '$Expected', получил '$Actual'"
    } else {
        Write-Host "OK:   $Name = '$Actual'"
    }
}

function Assert-True {
    param($Cond, [string]$Name)
    if (-not $Cond) { $script:failures++; Write-Host "FAIL: $Name" }
    else { Write-Host "OK:   $Name" }
}

# Чтение файла без BOM, массив строк
function Get-ContentClean {
    param([string]$Path)
    $enc = [System.Text.Encoding]::UTF8
    $txt = [System.IO.File]::ReadAllText($Path, $enc)
    if ($txt -match '^\xEF\xBB\xBF') { $txt = $txt.Substring(1) }
    return $txt -split "`r?`n"
}

# Итог: выводит PASS/FAILURES и завершает скрипт
function Exit-Tests {
    Write-Host ""
    if ($script:failures -gt 0) {
        Write-Host "FAILURES: $script:failures"
        exit 1
    }
    Write-Host "ALL TESTS PASSED"
    exit 0
}
