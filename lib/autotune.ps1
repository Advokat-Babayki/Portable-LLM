# =====================================================
# autotune.ps1 — Windows: авто-подбор параметров запуска LLM
# Вызывается из Windows.bat:
#   for /f "usebackq delims=" %%a in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\autotune.ps1" -Model "model.gguf" -Backend "cpu" -ModelDir "%~dp0models"`) do set "%%a"
# Печатает строки KEY=VALUE: LLM_CTX, LLM_NGL, LLM_THREADS, LLM_BATCH,
# LLM_UB, LLM_MODEL_MB, LLM_MOE, LLM_EXPERTS.
# При любой ошибке — безопасные значения по умолчанию (запуск не падает).
# =====================================================
param(
    [string]$Model = "",
    [string]$Backend = "cpu",
    [string]$ModelDir = "models"
)

# --- значения по умолчанию ---
$ctx     = 2048
$ngl     = 0
$threads = 1
$batch   = 256
$ub      = 512
$sizeMb  = 4000
$moe     = $false
$experts = 0

try {
    . "$PSScriptRoot\detect_hw.ps1"   # Detect-Hardware выполняется автоматически
    . "$PSScriptRoot\common.ps1"

    $sizeMb  = Get-ModelSizeMB -Filename $Model -BaseDir $ModelDir
    $ctx     = Estimate-Context -VRAMMB $HW_VULKAN_VRAM_MB -RAMMB $HW_RAM_TOTAL_MB

    $threads = $HW_THREADS
    if ($threads -lt 1) { $threads = 1 }

    if ($Backend -eq "vulkan") {
        $batch = 512
        if ($HW_VULKAN_FOUND) {
            if (Test-MOEModel -Filename $Model) {
                $moe = $true
                $experts = Get-MOEExpertCount -Filename $Model
                if ($experts -lt 1) { $experts = 8 }
                $ngl = Get-MOENGL -VRAMMB $HW_VULKAN_VRAM_MB -ModelMB $sizeMb -Experts $experts
            } else {
                $ngl = Estimate-NGL -VRAMMB $HW_VULKAN_VRAM_MB -ModelMB $sizeMb
            }
        }
    }
} catch {
    # любая ошибка → остаются значения по умолчанию выше
}

Write-Output "LLM_CTX=$ctx"
Write-Output "LLM_NGL=$ngl"
Write-Output "LLM_THREADS=$threads"
Write-Output "LLM_BATCH=$batch"
Write-Output "LLM_UB=$ub"
Write-Output "LLM_MODEL_MB=$sizeMb"
Write-Output "LLM_MOE=$moe"
Write-Output "LLM_EXPERTS=$experts"
