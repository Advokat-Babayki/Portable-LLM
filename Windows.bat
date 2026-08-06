$content = @'
@echo off
chcp 65001 > nul
setlocal enabledelayedexpansion

cd /d "%~dp0"

:: =====================================================
:: ПРОВЕРКА И СКАЧИВАНИЕ БИНАРНИКОВ (при первом запуске)
:: Бинарники НЕ лежат в репозитории — берём официальные
:: сборки llama.cpp и whisper.cpp с GitHub.
:: Обновление: поменяй версии ниже и удали папки bin\ и
:: whisper\bin\ (или отдельные подпапки).
:: =====================================================
set "LLAMA_VERSION=b9932"
set "WHISPER_VERSION=v1.9.2"
set "LLAMA_URL_BASE=https://github.com/ggml-org/llama.cpp/releases/download/%LLAMA_VERSION%"
set "WHISPER_URL_BASE=https://github.com/ggml-org/whisper.cpp/releases/download/%WHISPER_VERSION%"

:check_bins
if exist "%~dp0bin\win-cpu\llama-server.exe" if exist "%~dp0bin\win-vulkan\llama-server.exe" if exist "%~dp0whisper\bin\win-cpu\whisper-server.exe" goto main_menu

cls
echo ===================================================
echo   Скачивание необходимых бинарников...
echo   llama.cpp %LLAMA_VERSION% + whisper.cpp %WHISPER_VERSION%
echo   (официальные сборки ggml-org, скачиваются один раз)
echo ===================================================
echo.

set "A_LLAMA_CPU=%TEMP%\llm-llama-cpu.zip"
set "A_LLAMA_VK=%TEMP%\llm-llama-vk.zip"
set "A_WHISPER=%TEMP%\llm-whisper.zip"
set "BIN_TMP=%TEMP%\llm-bins-tmp"

echo [LLM CPU] скачивание и установка...
call :download_file "%LLAMA_URL_BASE%/llama-%LLAMA_VERSION%-bin-win-cpu-x64.zip" "%A_LLAMA_CPU%"
if errorlevel 1 goto dl_failed
call :unpack_bin "%A_LLAMA_CPU%" "%~dp0bin\win-cpu" "llama-server.exe"
if errorlevel 1 goto extract_failed

echo [LLM Vulkan] скачивание и установка...
call :download_file "%LLAMA_URL_BASE%/llama-%LLAMA_VERSION%-bin-win-vulkan-x64.zip" "%A_LLAMA_VK%"
if errorlevel 1 goto dl_failed
call :unpack_bin "%A_LLAMA_VK%" "%~dp0bin\win-vulkan" "llama-server.exe"
if errorlevel 1 goto extract_failed

echo [Whisper CPU] скачивание и установка...
call :download_file "%WHISPER_URL_BASE%/whisper-bin-x64.zip" "%A_WHISPER%"
if errorlevel 1 goto dl_failed
call :unpack_bin "%A_WHISPER%" "%~dp0whisper\bin\win-cpu" "whisper-server.exe"
if errorlevel 1 goto extract_failed

echo.
echo Бинарники готовы. Запускаю лаунчер...
timeout /t 2 /nobreak >nul
goto main_menu

:dl_failed
echo.
echo [!] Ошибка скачивания. Проверьте интернет-соединение и версии:
echo   LLAMA_VERSION=%LLAMA_VERSION%   WHISPER_VERSION=%WHISPER_VERSION%
echo   llama.cpp:   https://github.com/ggml-org/llama.cpp/releases
echo   whisper.cpp: https://github.com/ggml-org/whisper.cpp/releases
pause
exit /b 1

:extract_failed
echo.
echo [!] Ошибка распаковки бинарника. Повторите запуск или скачайте архивы вручную.
pause
exit /b 1

:download_file
set "DL_URL=%~1"
set "DL_OUT=%~2"
where curl.exe >nul 2>nul
if not errorlevel 1 (
    curl.exe -fSL --retry 5 --connect-timeout 15 -o "%DL_OUT%" "%DL_URL%"
) else (
    echo [i] curl не найден, использую PowerShell...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%DL_URL%' -OutFile '%DL_OUT%'"
)
if errorlevel 1 exit /b 1
exit /b 0

:unpack_bin
set "UP_ZIP=%~1"
set "UP_DEST=%~2"
set "UP_KEY=%~3"

for %%A in ("%UP_ZIP%") do set "UP_SIZE=%%~zA"
if not defined UP_SIZE set "UP_SIZE=0"
if %UP_SIZE% LSS 1000000 (
    echo [!] Файл %UP_ZIP% слишком мал - вероятно, это страница ошибки вместо архива.
    exit /b 1
)

if exist "%BIN_TMP%" rmdir /s /q "%BIN_TMP%"
mkdir "%BIN_TMP%" >nul 2>nul

where tar.exe >nul 2>nul
if not errorlevel 1 (
    tar.exe -xf "%UP_ZIP%" -C "%BIN_TMP%"
) else (
    echo [i] tar не найден, использую PowerShell...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -Path '%UP_ZIP%' -DestinationPath '%BIN_TMP%' -Force"
)
if errorlevel 1 exit /b 1

for /d %%D in ("%BIN_TMP%\*") do (
    move /y "%%D\*" "%BIN_TMP%\" >nul 2>nul
    rmdir /s /q "%%D" 2>nul
)

if not exist "%UP_DEST%" mkdir "%UP_DEST%" >nul 2>nul
move /y "%BIN_TMP%\*" "%UP_DEST%\" >nul 2>nul
del /q "%UP_ZIP%" >nul 2>nul

if not exist "%UP_DEST%\%UP_KEY%" exit /b 1
echo   [OK] %UP_KEY%
exit /b 0

:main_menu
cls
if exist "%~dp0lib\detect_hw.ps1" (
    for /f "usebackq delims=" %%a in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\detect_hw.ps1"`) do set "%%a"
)
echo ===================================================
echo          LLM & Whisper Launcher — Windows
echo ===================================================
echo.
if defined HW_CPU_VENDOR echo   CPU: %HW_CPU_VENDOR% ^| %HW_CPU_VIRT_CORES% потоков ^| %HW_RAM_TOTAL_MB% MB RAM
if defined HW_VULKAN_FOUND if "%HW_VULKAN_FOUND%"=="True" echo   GPU: %HW_VULKAN_DEVICE% ^| %HW_VULKAN_VRAM_MB% MB VRAM
if defined HW_REC_REASON echo   Рекомендация: %HW_REC_REASON%
echo.
echo   1) 💬 Текстовая нейросеть (LLM / Чат)
echo   2) 🎙️  Распознавание речи (Whisper)
echo   q) Выход
echo.
echo ===================================================
set "cat_choice="
set /p "cat_choice=Выберите категорию (1-2): "

if /i "%cat_choice%"=="q" exit
if "%cat_choice%"=="1" goto llm_menu
if "%cat_choice%"=="2" goto whisper_menu
goto main_menu


:: =====================================================
:: РАЗДЕЛ 1: LLM
:: =====================================================

:llm_menu
cls
echo ===================================================
echo             Выбор текстовой модели (LLM)
echo ===================================================
echo.

if defined count (
    for /l %%i in (1,1,!count!) do set "LLM_MODEL_%%i="
)
set "count=0"

if exist "%~dp0lib\detect_hw.ps1" (
    for /f "usebackq delims=" %%m in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%~dp0lib\detect_hw.ps1'; Get-ChildItem 'models\*.gguf' -ErrorAction SilentlyContinue | ForEach-Object { $n = $_.Name; $s = Get-ModelSizeMB -Filename $n -BaseDir 'models'; Write-Output ($n + '|' + $s) }"`) do (
        set /a count+=1
        for /f "tokens=1* delims=|" %%a in ("%%m") do set "LLM_MODEL_!count!=%%a" & set "LLM_SIZE_!count!=%%b"
    )
) else (
    for %%F in ("models\*.gguf") do (
        set /a count+=1
        set "LLM_MODEL_!count!=%%~nxF"
    )
)

if %count%==0 (
    echo [!] Папка models\ пуста! Положи .gguf файлы в: %~dp0models
    echo.
    pause
    goto main_menu
)

echo Доступные модели:
for /l %%i in (1,1,%count%) do (
    if "!LLM_SIZE_%%i!"=="" (
        echo   %%i^) !LLM_MODEL_%%i!
    ) else (
        echo   %%i^) !LLM_MODEL_%%i!  (~!LLM_SIZE_%%i! MB^)
    )
)
echo   b^) Назад в главное меню
echo.
echo ===================================================
set "m_choice="
set /p "m_choice=Выберите номер модели (1-%count%): "

if /i "%m_choice%"=="b" goto main_menu
if not defined m_choice goto llm_menu

set "valid=0"
for /l %%i in (1,1,%count%) do (
    if "%m_choice%"=="%%i" set "valid=1"
)
if "%valid%"=="0" (
    echo Неверный выбор!
    timeout /t 1 >nul
    goto llm_menu
)

for %%a in (!m_choice!) do set "SELECTED_MODEL=!LLM_MODEL_%%a!"

:llm_mode_menu
cls
echo ===================================================
echo Выбрана модель: !SELECTED_MODEL!
echo ===================================================
echo.
echo Режим работы:
echo   1) CPU    (Самый стабильный режим, без риска зависания)
echo   2) Vulkan (Ускорение на Vega 10 / GPU)
echo   b) Назад к выбору модели
echo.
echo ===================================================
set "r_choice="
set /p "r_choice=Выберите режим (1-2): "

if /i "%r_choice%"=="b" goto llm_menu
if "%r_choice%"=="1" goto run_llm_cpu
if "%r_choice%"=="2" goto run_llm_vulkan
goto llm_mode_menu

:run_llm_cpu
cls
set "LLM_BACKEND=cpu"
set "LLM_BINDIR=bin\win-cpu"
goto run_llm_common

:run_llm_vulkan
cls
set "LLM_BACKEND=vulkan"
set "LLM_BINDIR=bin\win-vulkan"
goto run_llm_common

:run_llm_common
if not exist "%~dp0lib\autotune.ps1" goto run_llm_legacy

for /f "usebackq delims=" %%a in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\autotune.ps1" -Model "!SELECTED_MODEL!" -Backend "!LLM_BACKEND!" -ModelDir "%~dp0models"`) do set "%%a"
if not defined LLM_CTX set "LLM_CTX=2048"
if not defined LLM_NGL set "LLM_NGL=0"
if not defined LLM_THREADS set "LLM_THREADS=1"
if not defined LLM_BATCH set "LLM_BATCH=256"
if not defined LLM_UB set "LLM_UB=512"

set "LLM_PORT="
for /f "usebackq delims=" %%p in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%~dp0lib\common.ps1'; Find-FreePort 8080"`) do set "LLM_PORT=%%p"
if not defined LLM_PORT set "LLM_PORT=8080"

cls
echo ===================================================
echo Выбрана модель: !SELECTED_MODEL!
echo ===================================================
echo.
echo [Запуск LLM на !LLM_BACKEND!...]
echo Адрес веб-интерфейса: http://127.0.0.1:!LLM_PORT!
echo Параметры: ctx=!LLM_CTX! ngl=!LLM_NGL! threads=!LLM_THREADS! batch=!LLM_BATCH!
if "!LLM_MOE!"=="True" echo [*] Обнаружена MoE модель (!LLM_EXPERTS! экспертов)
echo (браузер откроется автоматически)
echo ===================================================
start /b "" cmd /c "ping -n 12 127.0.0.1 >nul & start "" "" http://127.0.0.1:!LLM_PORT!"

cd /d "%~dp0!LLM_BINDIR!"
if "!LLM_BACKEND!"=="vulkan" set "GGML_VK_VISIBLE_DEVICES=0"
set "LLM_EXIT=0"
llama-server.exe -m "..\..\models\!SELECTED_MODEL!" -c !LLM_CTX! -ngl !LLM_NGL! -t !LLM_THREADS! -b !LLM_BATCH! -ub !LLM_UB! --host 127.0.0.1 --port !LLM_PORT!
set "LLM_EXIT=!errorlevel!"
cd /d "%~dp0"

echo.
echo Сервер остановлен (код: !LLM_EXIT!).
if not "!LLM_EXIT!"=="0" if not "!LLM_EXIT!"=="1" if not "!LLM_EXIT!"=="2" if not "!LLM_EXIT!"=="3221225786" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%~dp0lib\common.ps1'; . '%~dp0lib\detect_hw.ps1'; New-CrashReport -Mode 'LLM' -Backend '!LLM_BACKEND!' -Model '!SELECTED_MODEL!' -Params 'ctx=!LLM_CTX! ngl=!LLM_NGL! threads=!LLM_THREADS! batch=!LLM_BATCH! port=!LLM_PORT!' -ExitCode !LLM_EXIT!"
)
pause
goto llm_menu

:run_llm_legacy
cls
echo ===================================================
echo Выбрана модель: !SELECTED_MODEL!
echo ===================================================
echo.
echo [Запуск LLM на !LLM_BACKEND! (режим совместимости)...]
echo Адрес веб-интерфейса: http://127.0.0.1:8080
echo.
cd /d "%~dp0!LLM_BINDIR!"
if "!LLM_BACKEND!"=="vulkan" (
    set "GGML_VK_VISIBLE_DEVICES=0"
    llama-server.exe -m "..\..\models\!SELECTED_MODEL!" -ngl 99 -c 2048 -np 1 --host 127.0.0.1 --port 8080
) else (
    llama-server.exe -m "..\..\models\!SELECTED_MODEL!" -c 2048 -np 1 --host 127.0.0.1 --port 8080
)
set "LLM_EXIT=!errorlevel!"
cd /d "%~dp0"
echo.
echo Сервер остановлен (код: !LLM_EXIT!).
pause
goto llm_menu


:: =====================================================
:: РАЗДЕЛ 2: WHISPER
:: =====================================================

:whisper_menu
cls
echo ===================================================
echo          Выбор модели Whisper (Аудио в текст)
echo ===================================================
echo.

if defined w_count (
    for /l %%i in (1,1,!w_count!) do set "W_MODEL_%%i="
)
set "w_count=0"

if exist "%~dp0lib\detect_hw.ps1" (
    for /f "usebackq delims=" %%m in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%~dp0lib\detect_hw.ps1'; Get-ChildItem 'whisper\models\*.bin','whisper\models\*.gguf' -ErrorAction SilentlyContinue | ForEach-Object { $n = $_.Name; $s = Get-ModelSizeMB -Filename $n -BaseDir 'whisper\models'; Write-Output ($n + '|' + $s) }"`) do (
        set /a w_count+=1
        for /f "tokens=1* delims=|" %%a in ("%%m") do set "W_MODEL_!w_count!=%%a" & set "W_SIZE_!w_count!=%%b"
    )
) else (
    for %%F in ("whisper\models\*.bin" "whisper\models\*.gguf") do (
        set /a w_count+=1
        set "W_MODEL_!w_count!=%%~nxF"
    )
)

if %w_count%==0 (
    echo [!] Папка whisper\models\ пуста!
    echo.
    pause
    goto main_menu
)

echo Доступные модели Whisper:
for /l %%i in (1,1,%w_count%) do (
    if "!W_SIZE_%%i!"=="" (
        echo   %%i^) !W_MODEL_%%i!
    ) else (
        echo   %%i^) !W_MODEL_%%i!  (~!W_SIZE_%%i! MB^)
    )
)
echo   b^) Назад в главное меню
echo.
echo ===================================================
set "w_choice="
set /p "w_choice=Выберите номер модели (1-%w_count%): "

if /i "%w_choice%"=="b" goto main_menu
if not defined w_choice goto whisper_menu

set "valid=0"
for /l %%i in (1,1,%w_count%) do (
    if "%w_choice%"=="%%i" set "valid=1"
)
if "%valid%"=="0" (
    echo Неверный выбор!
    timeout /t 1 >nul
    goto whisper_menu
)

for %%a in (!w_choice!) do set "SELECTED_W_MODEL=!W_MODEL_%%a!"

:whisper_mode_menu
cls
echo ===================================================
echo Выбрана модель Whisper: !SELECTED_W_MODEL!
echo ===================================================
echo.
echo Режим работы:
echo   1) CPU    (Процессор)
echo   (Vulkan для Whisper в официальных сборках не поставляется)
echo   b) Назад к выбору модели
echo.
echo ===================================================
set "wr_choice="
set /p "wr_choice=Выберите режим (1): "

if /i "%wr_choice%"=="b" goto whisper_menu
if "%wr_choice%"=="1" goto run_whisper_cpu
goto whisper_mode_menu

:run_whisper_cpu
cls
set "W_PORT="
if exist "%~dp0lib\common.ps1" (
    for /f "usebackq delims=" %%p in (`powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%~dp0lib\common.ps1'; Find-FreePort 8081"`) do set "W_PORT=%%p"
)
if not defined W_PORT set "W_PORT=8081"

echo.
echo [Запуск Whisper !SELECTED_W_MODEL! на CPU...]
echo Адрес веб-интерфейса: http://127.0.0.1:!W_PORT!
echo (браузер откроется автоматически)
start /b "" cmd /c "ping -n 8 127.0.0.1 >nul & start "" "" http://127.0.0.1:!W_PORT!"
cd /d "%~dp0whisper\bin\win-cpu"
set "W_EXIT=0"
whisper-server.exe -m "..\..\models\!SELECTED_W_MODEL!" --host 127.0.0.1 --port !W_PORT!
set "W_EXIT=!errorlevel!"
cd /d "%~dp0"
echo.
echo Сервер остановлен (код: !W_EXIT!).
if not "!W_EXIT!"=="0" if not "!W_EXIT!"=="1" if not "!W_EXIT!"=="2" if not "!W_EXIT!"=="3221225786" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ". '%~dp0lib\common.ps1'; . '%~dp0lib\detect_hw.ps1'; New-CrashReport -Mode 'WHISPER' -Backend 'cpu' -Model '!SELECTED_W_MODEL!' -Params 'port=!W_PORT!' -ExitCode !W_EXIT!"
)
pause
goto whisper_menu
'@

[System.IO.File]::WriteAllText("Windows.bat", $content, [System.Text.Encoding]::UTF8)
