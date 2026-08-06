# =====================================================
# detect_hw.ps1 — Hardware detection for Windows
# Sets global variables in script scope
# =====================================================

function Detect-HardwareImpl {
    # --- CPU ---
    $cpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cpuVendor = $cpuInfo.VendorID
    $physCores = $cpuInfo.NumberOfCores
    $virtCores = $cpuInfo.NumberOfLogicalProcessors
    if (-not $virtCores -or $virtCores -lt 1) { $virtCores = $physCores }
    if (-not $physCores -or $physCores -lt 1) { $physCores = 1 }

    # CPU feature flags from registry
    $featureSet = (Get-ItemProperty "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0").FeatureSet
    $hasAVX2 = ($featureSet -band 0x20) -ne 0
    $hasAVX512 = ($featureSet -band 0x40000) -ne 0
    $hasAVX512_VNNI = ($featureSet -band 0x400000) -ne 0
    $hasAMX = ($featureSet -band 0x10000000) -ne 0

    # Determine best CPU variant
    if ($hasAVX512 -and $hasAVX512_VNNI -and $hasAMX) {
        $cpuBestVariant = "sapphirerapids"
    } elseif ($hasAVX512 -and $hasAVX2) {
        $cpuBestVariant = "sapphirerapids"
    } elseif ($hasAVX2) {
        $cpuBestVariant = "haswell"
    } else {
        $cpuBestVariant = "x64"
    }

    # --- RAM ---
    $cs = Get-CimInstance Win32_ComputerSystem
    $ramTotalMB = [math]::Floor($cs.TotalPhysicalMemory / 1MB)
    $ramAvailMB = $ramTotalMB # No easy way without calling GlobalMemoryStatusEx; approximate

    # --- GPU (Vulkan) ---
    $vulkanFound = $false
    $vulkanVendor = ""
    $vulkanVRAMMB = 0
    $vulkanDeviceName = ""
    $vulkanDeviceType = ""

    if (Get-Command vulkaninfo -ErrorAction SilentlyContinue) {
        try {
            $vkOutput = & vulkaninfo --summary 2>$null
            if ($vkOutput) {
                $vulkanFound = $true

                # Extract device name
                $nameLine = $vkOutput | Select-String -Pattern 'deviceName\s*=' | Select-Object -First 1
                if ($nameLine) {
                    $vulkanDeviceName = ($nameLine.Line -split '=', 2)[1].Trim()
                }

                # Extract device type (INTEGRATED_GPU / DISCRETE_GPU)
                $typeLine = $vkOutput | Select-String -Pattern 'deviceType\s*=' | Select-Object -First 1
                if ($typeLine) {
                    $vulkanDeviceType = ($typeLine.Line -split '=', 2)[1].Trim()
                }

                # For discrete GPUs, try to get VRAM from full vulkaninfo
                if ($vulkanDeviceType -match "DISCRETE") {
                    $vkFull = & vulkaninfo 2>$null
                    if ($vkFull) {
                        # Memory heap parsing — look for VkPhysicalDeviceMemoryProperties section
                        $memProps = $vkFull | Select-String -Pattern 'VkPhysicalDeviceMemoryProperties' -Context 0, 20
                        if ($memProps) {
                            $heapSizeLine = $memProps.Context.PostContext | Select-String -Pattern 'size\s*=\s*(\d+)' | Select-Object -First 1
                            if ($heapSizeLine) {
                                $heapSize = [long]$heapSizeLine.Matches.Groups[1].Value
                                if ($heapSize -gt 100MB) {
                                    $vulkanVRAMMB = [math]::Floor($heapSize / 1MB)
                                }
                            }
                        }
                    }
                }

                # Vendor detection from deviceName
                switch -Wildcard ($vulkanDeviceName) {
                    "*AMD*" { $vulkanVendor = "amd" }
                    "*Radeon*" { $vulkanVendor = "amd" }
                    "*NVIDIA*" { $vulkanVendor = "nvidia" }
                    "*GeForce*" { $vulkanVendor = "nvidia" }
                    "*Quadro*" { $vulkanVendor = "nvidia" }
                    "*Intel*" { $vulkanVendor = "intel" }
                    "*HD Graphics*" { $vulkanVendor = "intel" }
                }
            }
        } catch {
            # vulkaninfo failed, assume no Vulkan
        }
    }

    # --- Determine backend recommendation ---
    $recBackend = "cpu-base"
    $recReason = "Базовый CPU"

    if ($vulkanFound) {
        if ($vulkanVRAMMB -ge 4096) {
            $recBackend = "vulkan"
            $recReason = "GPU: $vulkanDeviceName ($vulkanVRAMMB MB VRAM)"
        } elseif ($vulkanVRAMMB -ge 1024) {
            $recBackend = "vulkan"
            $recReason = "GPU: $vulkanDeviceName ($vulkanVRAMMB MB VRAM, может быть маловато)"
        } elseif ($vulkanDeviceType -match "INTEGRATED") {
            # Integrated GPU — recommend CPU but Vulkan is available
            if ($hasAVX512 -and $hasAVX512_VNNI) {
                $recBackend = "cpu-avx512"
                $recReason = "AVX-512 (CPU) — интегрированная GPU, но Vulkan доступен"
            } elseif ($hasAVX2) {
                $recBackend = "cpu-avx2"
                $recReason = "AVX2 (CPU) — интегрированная GPU, но Vulkan доступен"
            } else {
                $recBackend = "cpu-base"
                $recReason = "Базовый CPU — интегрированная GPU, но Vulkan доступен"
            }
        } else {
            $recBackend = "vulkan"
            $recReason = "GPU: $vulkanDeviceName (VRAM: ${vulkanVRAMMB}MB)"
        }
    } elseif ($hasAVX512 -and $hasAVX512_VNNI) {
        $recBackend = "cpu-avx512"
        $recReason = "AVX-512 + VNNI (CPU)"
    } elseif ($hasAVX2) {
        $recBackend = "cpu-avx2"
        $recReason = "AVX2 (CPU)"
    }

    # --- Export variables ---
    $script:HW_OS = "windows"
    $script:HW_CPU_VENDOR = $cpuVendor
    $script:HW_CPU_PHYS_CORES = $physCores
    $script:HW_CPU_VIRT_CORES = $virtCores
    $script:HW_HAS_AVX2 = $hasAVX2
    $script:HW_HAS_AVX512 = $hasAVX512
    $script:HW_HAS_AVX512_VNNI = $hasAVX512_VNNI
    $script:HW_HAS_AMX = $hasAMX
    $script:HW_CPU_BEST_VARIANT = $cpuBestVariant
    $script:HW_RAM_TOTAL_MB = $ramTotalMB
    $script:HW_RAM_AVAIL_MB = $ramAvailMB
    $script:HW_VULKAN_FOUND = $vulkanFound
    $script:HW_VULKAN_VENDOR = $vulkanVendor
    $script:HW_VULKAN_VRAM_MB = $vulkanVRAMMB
    $script:HW_VULKAN_DEVICE = $vulkanDeviceName
    $script:HW_VULKAN_DEVICE_TYPE = $vulkanDeviceType
    $script:HW_REC_BACKEND = $recBackend
    $script:HW_REC_REASON = $recReason
    $script:HW_THREADS = $physCores
    if ($script:HW_THREADS -lt 1) { $script:HW_THREADS = 1 }
}

# --- Обёртка: безопасные значения по умолчанию + защита от исключений ---
# (если WMI/реестр/vulkaninfo сбоят — детект не роняет запуск)
function Detect-Hardware {
    $script:HW_OS = "windows"
    $script:HW_CPU_VENDOR = ""
    $script:HW_CPU_PHYS_CORES = 0
    $script:HW_CPU_VIRT_CORES = 0
    $script:HW_HAS_AVX2 = $false
    $script:HW_HAS_AVX512 = $false
    $script:HW_HAS_AVX512_VNNI = $false
    $script:HW_HAS_AMX = $false
    $script:HW_CPU_BEST_VARIANT = "x64"
    $script:HW_RAM_TOTAL_MB = 0
    $script:HW_RAM_AVAIL_MB = 0
    $script:HW_VULKAN_FOUND = $false
    $script:HW_VULKAN_VENDOR = ""
    $script:HW_VULKAN_VRAM_MB = 0
    $script:HW_VULKAN_DEVICE = ""
    $script:HW_VULKAN_DEVICE_TYPE = ""
    $script:HW_REC_BACKEND = "cpu-base"
    $script:HW_REC_REASON = "Базовый CPU"
    $script:HW_THREADS = 1

    try {
        Detect-HardwareImpl
    } catch {
        # Ошибка детекта не критична — остаются значения по умолчанию
    }

    if (-not $script:HW_CPU_VIRT_CORES -or $script:HW_CPU_VIRT_CORES -lt 1) { $script:HW_CPU_VIRT_CORES = 1 }
    if (-not $script:HW_CPU_PHYS_CORES -or $script:HW_CPU_PHYS_CORES -lt 1) { $script:HW_CPU_PHYS_CORES = $script:HW_CPU_VIRT_CORES }
    if ($script:HW_THREADS -lt 1) { $script:HW_THREADS = 1 }
    # VendorID может вернуть null/пустоту в изолированных окружениях (CI) — не оставляем null
    if ([string]::IsNullOrEmpty([string]$script:HW_CPU_VENDOR)) { $script:HW_CPU_VENDOR = "unknown" }
}

Detect-Hardware

# --- Экспорт KEY=VALUE для .bat, если файл запущен напрямую ---
# ($MyInvocation.InvocationName -ne '.' означает прямой запуск, не dot-source)
if ($MyInvocation.InvocationName -ne '.') {
    function Export-HWLine([string]$Name, $Value) {
        $s = [string]$Value
        # Убираем символы, ломающие разбор в cmd (скобки, &, |, %, ^, !, <>)
        $s = $s -replace '[()&|%^!<>]', '_'
        "$Name=$s"
    }
    Export-HWLine "HW_OS"                    $script:HW_OS
    Export-HWLine "HW_CPU_VENDOR"            $script:HW_CPU_VENDOR
    Export-HWLine "HW_CPU_PHYS_CORES"        $script:HW_CPU_PHYS_CORES
    Export-HWLine "HW_CPU_VIRT_CORES"        $script:HW_CPU_VIRT_CORES
    Export-HWLine "HW_HAS_AVX2"              $script:HW_HAS_AVX2
    Export-HWLine "HW_HAS_AVX512"            $script:HW_HAS_AVX512
    Export-HWLine "HW_RAM_TOTAL_MB"          $script:HW_RAM_TOTAL_MB
    Export-HWLine "HW_VULKAN_FOUND"          $script:HW_VULKAN_FOUND
    Export-HWLine "HW_VULKAN_VENDOR"         $script:HW_VULKAN_VENDOR
    Export-HWLine "HW_VULKAN_VRAM_MB"        $script:HW_VULKAN_VRAM_MB
    Export-HWLine "HW_VULKAN_DEVICE"         $script:HW_VULKAN_DEVICE
    Export-HWLine "HW_REC_BACKEND"           $script:HW_REC_BACKEND
    Export-HWLine "HW_REC_REASON"            $script:HW_REC_REASON
    Export-HWLine "HW_THREADS"               $script:HW_THREADS
}

# --- Helper: Estimate ngl for a given model size in MB ---
function Estimate-NGL {
    param(
        [int]$VRAMMB,
        [int]$ModelMB
    )
    if ($ModelMB -eq 0) { return 99 }
    $usableVRAM = $VRAMMB * 0.8
    $perLayer = $ModelMB / 32
    if ($perLayer -lt 50) { $perLayer = 50 }
    $ngl = [math]::Floor($usableVRAM / $perLayer)
    if ($ngl -gt 99) { $ngl = 99 }
    if ($ngl -lt 1) { $ngl = 1 }
    return $ngl
}

# --- Helper: Estimate context size ---
function Estimate-Context {
    param(
        [int]$VRAMMB,
        [int]$RAMMB
    )
    if ($VRAMMB -ge 4096) { return 8192 }
    elseif ($RAMMB -ge 16000) { return 4096 }
    else { return 2048 }
}

# --- Helper: Get model size in MB from filename (with quantization awareness) ---
function Get-ModelSizeMB {
    param(
        [string]$Filename,
        [string]$BaseDir = ""
    )
    
    # 1. Extract parameter size from filename (e.g., 7B, 14B, 0.5B, 32B)
    $match = [regex]::Match($Filename, '(\d+(?:\.\d+)?)B', 'IgnoreCase')
    if ($match.Success) {
        $paramBillions = [double]$match.Groups[1].Value
        
        # 2. Detect quantization type from filename
        $quantFactor = 0.7
        $fnameUpper = $Filename.ToUpper()
        
        switch -Regex ($fnameUpper) {
            {$_ -match "IQ4_NL|IQ4"} { $quantFactor = 0.52; break }
            {$_ -match "Q2_K|IQ2_"} { $quantFactor = 1.0; break }
            {$_ -match "Q3_K_M"} { $quantFactor = 0.64; break }
            {$_ -match "Q3_K_S"} { $quantFactor = 0.58; break }
            {$_ -match "Q3_K"} { $quantFactor = 0.61; break }
            {$_ -match "Q3_"} { $quantFactor = 0.59; break }
            {$_ -match "Q4_0|Q4_1"} { $quantFactor = 0.55; break }
            {$_ -match "Q4_K_S"} { $quantFactor = 0.53; break }
            {$_ -match "Q4_K_XL"} { $quantFactor = 0.57; break }
            {$_ -match "Q4_K_M"} { $quantFactor = 0.56; break }
            {$_ -match "Q4_K_L"} { $quantFactor = 0.60; break }
            {$_ -match "Q4_K"} { $quantFactor = 0.57; break }
            {$_ -match "Q4_"} { $quantFactor = 0.55; break }
            {$_ -match "Q5_0|Q5_1"} { $quantFactor = 0.75; break }
            {$_ -match "Q5_K_S"} { $quantFactor = 0.72; break }
            {$_ -match "Q5_K_M"} { $quantFactor = 0.78; break }
            {$_ -match "Q5_K"} { $quantFactor = 0.75; break }
            {$_ -match "Q5_"} { $quantFactor = 0.76; break }
            {$_ -match "Q6_K"} { $quantFactor = 0.85; break }
            {$_ -match "Q6_"} { $quantFactor = 0.85; break }
            {$_ -match "Q8_0"} { $quantFactor = 1.20; break }
            {$_ -match "Q8_1"} { $quantFactor = 1.19; break }
            {$_ -match "Q8_"} { $quantFactor = 1.20; break }
            {$_ -match "Q2_"} { $quantFactor = 1.0; break }
            {$_ -match "Q3_"} { $quantFactor = 0.60; break }
            {$_ -match "Q4_"} { $quantFactor = 0.56; break }
            {$_ -match "Q5_"} { $quantFactor = 0.75; break }
            {$_ -match "Q6_"} { $quantFactor = 0.85; break }
            {$_ -match "Q8_"} { $quantFactor = 1.20; break }
            {$_ -match "F16|FP16"} { $quantFactor = 2.10; break }
            {$_ -match "F32|FP32"} { $quantFactor = 4.20; break }
            default { $quantFactor = 0.70 }
        }
        
        return [int]($paramBillions * 1024 * $quantFactor)
    }
    
    # 3. No parameter count in filename — try file size on disk
    if ($BaseDir -and (Test-Path "$BaseDir\$Filename")) {
        $item = Get-Item "$BaseDir\$Filename"
        return [int]($item.Length / 1MB)
    }
    return 4000
}

# --- Helper: Detect if model is Mixture-of-Experts (MoE) ---
function Test-MOEModel {
    param([string]$Filename)
    $fnameUpper = $Filename.ToUpper()
    
    switch -Regex ($fnameUpper) {
        "MOE|MIXTRAL|DEEPSEEK-V2|DEEPSEEK-V3|DOLPHIN-MIX|EXPERT|ROUTED|SPARSE" {
            return $true
        }
        "\d+X\d+[BM]" {
            return $true
        }
        default {
            return $false
        }
    }
}

# --- Helper: Get MoE expert count from filename ---
function Get-MOEExpertCount {
    param([string]$Filename)
    $fnameUpper = $Filename.ToUpper()
    
    # Pattern like 8X7B, 16X7B, 32X1B
    $match = [regex]::Match($fnameUpper, '(\d+)X\d+[BM]', 'IgnoreCase')
    if ($match.Success) {
        return [int]$match.Groups[1].Value
    }
    
    # Fallback for models with -moe suffix but no XxY pattern
    # Common defaults: Mixtral = 8, DeepSeek = 64, others = 8
    switch -Regex ($fnameUpper) {
        "DEEPSEEK.*MOE|DEEPSEEK-V2.*MOE|DEEPSEEK-V3.*MOE" { return 64 }
        default { return 8 }  # Default: assume 8 experts (Mixtral-style)
    }
}

# --- Helper: Get recommended ngl for MoE model ---
function Get-MOENGL {
    param(
        [int]$VRAMMB,
        [int]$ModelMB,
        [int]$Experts
    )
    if (-not $Experts -or $Experts -eq 0) {
        return (Estimate-NGL -VRAMMB $VRAMMB -ModelMB $ModelMB)
    }
    
    # For MoE: reserve 40% of VRAM for active expert caching
    $usableVRAM = $VRAMMB * 0.6
    $perLayer = $ModelMB / 32
    if ($perLayer -lt 50) { $perLayer = 50 }
    $ngl = [math]::Floor($usableVRAM / $perLayer)
    
    if ($ngl -gt 32) { $ngl = 32 }  # Cap MoE GPU layers
    if ($ngl -lt 1) { $ngl = 1 }
    return $ngl
}
