# =====================================================
# common.ps1 — Shared functions for Windows.bat (Windows)
# =====================================================

# --- Ensure binaries exist ---
function Ensure-Binaries {
    $dirs = @("bin\win-cpu", "bin\win-vulkan", "whisper\bin\win-cpu", "whisper\bin\win-vulkan")
    foreach ($dir in $dirs) {
        if (Test-Path $dir) {
            # Windows .exe files don't need chmod
        }
    }
}

# --- Find a free port starting from base ---
function Find-FreePort {
    param([int]$BasePort)
    $port = $BasePort
    while ($port -le 65535) {
        try {
            $tcp = New-Object Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $port)
            $tcp.Close()
            # Port is open, try next
            $port++
        } catch {
            # Port is free
            return $port
        }
    }
    return $BasePort
}

# --- Wait for server to be ready ---
function Wait-ForServer {
    param(
        [int]$Port,
        [int]$MaxWait = 60
    )
    $waited = 0
    while ($waited -lt $MaxWait) {
        try {
            $req = [Net.WebRequest]::Create("http://127.0.0.1:$Port")
            $req.Timeout = 2000
            $req.GetResponse() | Out-Null
            return $true
        } catch {
            # Not ready yet
        }
        Start-Sleep -Seconds 2
        $waited += 2
    }
    return $false
}

# --- Scan models in a directory ---
function Scan-Models {
    param([string]$Dir)
    
    if (-not (Test-Path $Dir)) {
        return @()
    }
    
    $extensions = @("gguf", "bin")
    $files = @()
    
    foreach ($ext in $extensions) {
        $files += Get-ChildItem -Path $Dir -Filter "*.$ext" -File -ErrorAction SilentlyContinue |
                  Select-Object -ExpandProperty Name
    }
    
    return $files
}

# --- Print hardware info summary ---
function Print-HWInfo {
    Write-Host "==================================================="
    Write-Host "  Система: $($HW_OS)"
    Write-Host "  CPU: $($HW_CPU_VENDOR) | $($HW_CPU_VIRT_CORES) потоков | $($HW_RAM_TOTAL_MB) MB RAM"
    Write-Host "  AVX2: $($HW_HAS_AVX2) | AVX-512: $($HW_HAS_AVX512)"
    if ($HW_VULKAN_FOUND) {
        Write-Host "  GPU: $($HW_VULKAN_DEVICE) | $($HW_VULKAN_VENDOR) | $($HW_VULKAN_VRAM_MB) MB VRAM"
    } else {
        Write-Host "  GPU: Не обнаружен Vulkan"
    }
    Write-Host "  Рекомендация: $($HW_REC_REASON)"
    Write-Host "==================================================="
}

# --- Select model interactively ---
function Select-Model {
    param(
        [string]$Dir,
        [string]$Prompt
    )
    
    $models = Scan-Models -Dir $Dir
    
    if ($models.Count -eq 0) {
        Write-Host "[!] $Prompt папка пуста: $Dir"
        Write-Host "Положите .gguf/.bin файлы в эту папку."
        pause
        return $null
    }
    
    Write-Host "Доступные модели:"
    for ($i = 0; $i -lt $models.Count; $i++) {
        $size = Get-ModelSizeMB -Filename $models[$i] -BaseDir $Dir
        Write-Host "  $($i+1)) $($models[$i]) (~$size MB)"
    }
    Write-Host "  b) Назад"
    Write-Host ""
    
    $choice = Read-Host "Выберите модель (1-$($models.Count))"
    
    if ($choice -match '^[bB]$') {
        return $null
    }
    
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $models.Count) {
        return $models[[int]$choice - 1]
    }
    
    Write-Host "Неверный выбор!"
    Start-Sleep -Seconds 1
    return $null
}

# --- Run server with crash logging ---
# ВНИМАНИЕ: stdout и stderr пишем в РАЗНЫЕ файлы через Start-Process.
# Это исключает deadlock на переполненном буфере stderr (баг исходной версии,
# из-за которого запуск зависал под Windows после запуска llama-server).
function Run-With-CrashLog {
    param(
        [string]$Mode,
        [string]$Backend,
        [string]$BinPath,
        [string[]]$CmdArgs
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logDir = "logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }

    $runLog = "$logDir\run_${timestamp}_${Mode}.log"
    $errLog = "$logDir\run_${timestamp}_${Mode}.err.log"

    Write-Host "[*] Запуск: $BinPath"
    Write-Host "[*] Папка для логов: logs\"
    Write-Host "========================================"

    $exitCode = -1
    try {
        $proc = Start-Process -FilePath $BinPath -ArgumentList $CmdArgs -NoNewWindow `
            -PassThru -RedirectStandardOutput $runLog -RedirectStandardError $errLog
        $proc.WaitForExit()
        # PS 5.1 с -NoNewWindow не обновляет ExitCode без явного Refresh
        $null = $proc.Refresh()
        $exitCode = $proc.ExitCode

        # Показать начало вывода (для проверки "listening")
        if (Test-Path $runLog) {
            Get-Content $runLog -TotalCount 30 | ForEach-Object { Write-Host $_ }
        }
    } catch {
        $exitCode = -1
        Write-Host "[!] Ошибка запуска: $($_.Exception.Message)"
        $_ | Out-String | Out-File -FilePath "$logDir\run_${timestamp}_error.log" -Encoding utf8
    }

    # --- Проверка на краш (исключаем штатные коды 0/1/2 и -1=ошибка запуска) ---
    if ($exitCode -ne 0 -and $exitCode -ne 1 -and $exitCode -ne 2 -and $exitCode -ne -1) {
        $crashFile = "$logDir\crash_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')_${Mode}.log"
        $report = @(
            "=== CRASH REPORT ==="
            "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "Backend: $Backend"
            "Mode: $Mode"
            "Exit code: $exitCode"
            "Args: $BinPath $($CmdArgs -join ' ')"
            "HW_OS: $($HW_OS)"
            "CPU: $($HW_CPU_VENDOR) ($($HW_CPU_VIRT_CORES) threads)"
            "RAM: $($HW_RAM_TOTAL_MB) MB total"
            if ($HW_VULKAN_FOUND) { "GPU: $($HW_VULKAN_DEVICE) ($($HW_VULKAN_VRAM_MB) MB)" }
            ""
            "=== STDOUT ==="
        )
        $report += Get-Content $runLog -ErrorAction SilentlyContinue
        if (Test-Path $errLog) {
            $report += ""
            $report += "=== STDERR ==="
            $report += Get-Content $errLog -ErrorAction SilentlyContinue
        }
        $report += "=== END ==="
        $report | Out-File -FilePath $crashFile -Encoding utf8
        Write-Host ""
        Write-Host "[!] КРАШ! Отчёт сохранён: $crashFile"
    }

    Remove-Item $runLog, $errLog -ErrorAction SilentlyContinue
    return $exitCode
}

# --- Write a short crash report (called from Windows.bat after abnormal exit) ---
# В отличие от Run-With-CrashLog, не перезапускает сервер: только пишет
# отчёт по уже завершившемуся процессу (exit-код передаёт .bat).
function New-CrashReport {
    param(
        [string]$Mode,          # LLM / WHISPER
        [string]$Backend,
        [string]$Model,
        [string]$Params,        # строка параметров запуска
        [int]$ExitCode
    )

    $logDir = "logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }

    $crashFile = "$logDir\crash_$(Get-Date -Format 'yyyyMMdd_HHmmss')_${Mode}.log"
    $report = @(
        "=== CRASH REPORT ==="
        "Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Backend: $Backend"
        "Mode: $Mode"
        "Exit code: $ExitCode"
        "Model: $Model"
        "Params: $Params"
        "HW_OS: $($HW_OS)"
        "CPU: $($HW_CPU_VENDOR) ($($HW_CPU_VIRT_CORES) threads)"
        "RAM: $($HW_RAM_TOTAL_MB) MB total"
        if ($HW_VULKAN_FOUND) { "GPU: $($HW_VULKAN_DEVICE) ($($HW_VULKAN_VRAM_MB) MB)" }
        ""
    )
    $report | Out-File -FilePath $crashFile -Encoding utf8
    Write-Host "[!] Краш! Отчёт сохранён: $crashFile"
}
