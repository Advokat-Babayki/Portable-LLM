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

# --- Helper: Estimate context size (fallback heuristic) ---
function Estimate-Context {
    param(
        [int]$VRAMMB,
        [int]$RAMMB
    )
    if ($VRAMMB -ge 4096) { return 8192 }
    elseif ($RAMMB -ge 16000) { return 4096 }
    else { return 2048 }
}

# ====================================================
#  GGUF metadata reader (Windows PowerShell).
#  Читает заголовок GGUF напрямую через BinaryReader —
#  зеркало bash-парсера из detect_hw.sh. Возвращает
#  hashtable {CtxLen, EmbedDim, Layers, HeadCount, KVHeads, HeadDim}
#  или $null при ошибке (вызывающий уходит в fallback).
# ====================================================
function Read-GgufMeta {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    $fs = $null
    $br = $null
    try {
        $item = Get-Item $Path
        if ($item.Length -lt 32) { return $null }
        $fs = [System.IO.File]::OpenRead($Path)
        $br = New-Object System.IO.BinaryReader $fs
        $magic = $br.ReadChars(4)
        if (($magic -join '') -ne 'GGUF') { return $null }
        $ver = [int]$br.ReadUInt32()
        if ($ver -lt 1) { return $null }
        $null = $br.ReadUInt64()   # tensor_count
        $kvCount = [int]$br.ReadUInt64()

        $meta = @{ Ctx=0; EmbedLen=0; Layers=0; Headers=0; KVHeads=0; HeadDim=0 }
        for ($i = 0; $i -lt $kvCount; $i++) {
            if ($fs.Position -ge $fs.Length) { break }
            $keyLen = [long]$br.ReadUInt64()
            $key = [System.Text.Encoding]::UTF8.GetString($br.ReadBytes([int]$keyLen))
            $vtype = [int]$br.ReadUInt32()

            switch ($vtype) {
                0 { $null = $br.ReadByte() }                      # uint8
                1 { $null = $br.ReadSByte() }                     # int8
                2 { $null = $br.ReadUInt16() }                    # uint16
                3 { $null = $br.ReadInt16() }                     # int16
                4 { $val = $br.ReadUInt32() }                     # uint32
                5 { $null = $br.ReadInt32() }                     # int32
                6 { $null = $br.ReadSingle() }                    # float32
                7 { $null = $br.ReadBoolean() }                   # bool
                8 {
                    $sl = [long]$br.ReadUInt64()                      # string
                    $null = $br.ReadBytes([int]$sl)
                }
                9 {
                    $et = [int]$br.ReadUInt32()                       # array
                    $cnt = [long]$br.ReadUInt64()
                    if ($et -eq 8) {
                        for ($a = 0; $a -lt $cnt; $a++) {
                            $es = [long]$br.ReadUInt64()
                            $null = $br.ReadBytes([int]$es)
                        }
                    } else {
                        $esize = switch ($et) {
                            0 {1} 1 {1} 2 {2} 3 {2} 7 {1}
                            10 {8} 11 {8} 12 {8} default {4}
                        }
                        $bytes = [math]::Min($cnt * $esize, $fs.Length - $fs.Position)
                        $null = $br.ReadBytes([int]$bytes)
                        if ($bytes -lt ($cnt * $esize)) { return $null }
                    }
                }
                10 { $null = $br.ReadUInt64() }                   # uint64
                11 { $null = $br.ReadInt64() }                    # int64
                12 { $null = $br.ReadDouble() }                   # float64
                default { return $null }
            }

            if ($vtype -eq 4) {
                switch -Wildcard ($key) {
                    '*.context_length'           { $meta.Ctx = [int]$val }
                    '*.embedding_length'         { $meta.EmbedLen = [int]$val }
                    '*.block_count'              { $meta.Layers = [int]$val }
                    '*.attention.head_count_kv'  { $meta.KVHeads = [int]$val }
                    '*.attention.head_count'     { $meta.Headers = [int]$val }
                    '*.attention.head_dim'       { $meta.HeadDim = [int]$val }
                }
            }

            # ранний выход (паритет с parse_gguf_meta): реальные GGUF кладут
            # все поля архитектуры до tokenizer.* — не читать их полностью.
            # KVHeads обязателен: без него nkv разъедется (см. qwen2.5: head_count
            # идёт раньше head_count_kv).
            if ($meta.Ctx -gt 0 -and $meta.Layers -gt 0 -and $meta.KVHeads -gt 0 -and
                ($meta.HeadDim -gt 0 -or $meta.EmbedLen -gt 0)) {
                break
            }
        }

        # derive: kv-heads → head_count; head_dim → n_embd / n_head
        if ($meta.Headers -le 0) { $meta.Headers = $meta.KVHeads }
        if ($meta.KVHeads  -le 0) { $meta.KVHeads  = $meta.Headers }
        if ($meta.HeadDim  -le 0) {
            if ($meta.EmbedLen -gt 0 -and $meta.Headers -gt 0) {
                $meta.HeadDim = [int]($meta.EmbedLen / $meta.Headers)
            } else {
                $meta.HeadDim = 128
            }
        }
        if ($meta.Ctx -le 0) { $meta.Ctx = 32768 }
        if ($meta.Layers -le 0 -or $meta.KVHeads -le 0) { return $null }
        return $meta
    } catch {
        return $null
    } finally {
        if ($br) { $br.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

# --- Context, рассчитанный по GGUF-метаданным и свободной памяти ---
# $1 = gguf file, $2 = backend (cpu|vulkan), $3 = free RAM MB,
# $4 = model MB, $5 = VRAM MB. Returns ctx, fallback к Estimate-Context.
function Get-RecommendedContext {
    param(
        [string]$ModelFile,
        [string]$Backend = "cpu",
        [int]$RAMAvailMB = 0,
        [int]$ModelMB = 4000,
        [int]$VRAMMB = 0
    )

    $meta = Read-GgufMeta -Path $ModelFile
    if ($null -eq $meta) {
        return (Estimate-Context -VRAMMB $VRAMMB -RAMMB $RAMAvailMB)
    }

    $reserve = 768
    $kvBytes = $meta.Layers * $meta.KVHeads * $meta.HeadDim * 4
    if ($kvBytes -lt 1) { $kvBytes = 1024 }

    $budget = if ($Backend -eq 'vulkan' -and $VRAMMB -gt $ModelMB) {
        $VRAMMB - $ModelMB
    } else {
        $RAMAvailMB - $ModelMB
    }
    $budget -= $reserve
    if ($budget -lt 0) { $budget = 0 }

    $ctx = [int][math]::Floor($budget * 1048576 / $kvBytes)
    if ($ctx -gt $meta.Ctx) { $ctx = $meta.Ctx }
    if ($ctx -lt 256) { $ctx = 256 }
    return $ctx
}

# --- Helper: quant-factor from the shared table lib/quant-factors.tsv ---
# Single source of truth: same table is used by bash (detect_hw.sh).
# Returns factor (e.g. 0.56) or fallback 0.70.
function Get-ModelQuantFactor {
    param([string]$Filename)
    $fnameUpper = $Filename.ToUpper()
    $table = Join-Path $PSScriptRoot 'quant-factors.tsv'
    if (-not (Test-Path $table)) { return 0.70 }
    foreach ($line in Get-Content $table) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $parts = $line -split "`t"
        if ($parts.Length -lt 2) { continue }
        $pattern = $parts[0].Trim()
        $factor  = [double]$parts[1]
        if ($fnameUpper -like $pattern) { return $factor }
    }
    return 0.70
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
        
        # 2. Quantization factor from the shared table (bash/PS parity)
        $quantFactor = Get-ModelQuantFactor -Filename $Filename
        
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
