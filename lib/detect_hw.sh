#!/bin/bash
# =====================================================
# detect_hw.sh — Hardware detection for Linux/macOS
# Outputs: sourceable environment variables
# =====================================================

detect_hardware() {
    # --- CPU ---
    local cpu_vendor=""
    local cpu_flags=""
    local phys_cores=0
    local virt_cores=0

    if command -v lscpu &>/dev/null; then
        # Multi-language lscpu parsing (English + Russian)
        cpu_vendor=$(lscpu | grep -m1 -E "Vendor ID|^ID прроизводителя|^Fabricante" | awk -F': *' '{print $2}')
        cpu_flags=$(lscpu | grep -m1 -E "^Flags|^Флаги" | awk -F': *' '{print $2}')
        # Fallback to /proc/cpuinfo for flags if lscpu parsing failed
        if [ -z "$cpu_flags" ] && [ -f /proc/cpuinfo ]; then
            cpu_flags=$(grep -m1 "^flags" /proc/cpuinfo | awk -F': *' '{print $2}')
        fi
        virt_cores=$(lscpu | grep -m1 -E "^CPU\(s\)|^Потоков" | awk -F': *' '{print $2}')
        # Fallback to /proc/cpuinfo for virtual cores
        if [ -z "$virt_cores" ] && [ -f /proc/cpuinfo ]; then
            virt_cores=$(grep -c "^processor" /proc/cpuinfo)
        fi
        # Physical cores: from "Ядер на сокет" * "Сокетов" or fallback
        local cores_per_socket
        cores_per_socket=$(lscpu | grep -m1 -E "^Core\(s\) per socket|^Ядер на сокет" | awk -F': *' '{print $2}')
        local sockets
        sockets=$(lscpu | grep -m1 -E "^Socket\(s\):|^Сокетов:" | awk -F': *' '{print $2}')
        if [ -n "$cores_per_socket" ] && [ -n "$sockets" ]; then
            phys_cores=$((cores_per_socket * sockets))
        else
            # Count unique Core,Socket pairs
            phys_cores=$(lscpu -p=Core,Socket 2>/dev/null | grep -v '^#' | cut -d, -f1 | sort -u | wc -l)
        fi
        if [ "$phys_cores" -lt 1 ]; then
            phys_cores="${virt_cores:-1}"
        fi
    elif [ -f /proc/cpuinfo ]; then
        cpu_vendor=$(grep -m1 "vendor_id" /proc/cpuinfo | awk -F': *' '{print $2}')
        cpu_flags=$(grep -m1 "flags" /proc/cpuinfo | awk -F': *' '{print $2}')
        virt_cores=$(grep -c "^processor" /proc/cpuinfo)
        phys_cores=$virt_cores
    fi

    # --- CPU feature flags ---
    HAS_AVX2=false
    HAS_AVX512=false
    HAS_AVX512_VNNI=false
    HAS_AMX=false

    case "$cpu_flags" in
        *" avx2 "*) HAS_AVX2=true ;;
    esac

    case "$cpu_flags" in
        *" avx512f "*) HAS_AVX512=true ;;
    esac

    case "$cpu_flags" in
        *" avx512_vnni "*) HAS_AVX512_VNNI=true ;;
    esac

    case "$cpu_flags" in
        *" amx "*) HAS_AMX=true ;;
    esac

    # --- Determine best CPU variant ---
    if $HAS_AVX512_VNNI && $HAS_AMX; then
        CPU_BEST_VARIANT="sapphirerapids"
    elif $HAS_AVX512 && $HAS_AVX2; then
        CPU_BEST_VARIANT="sapphirerapids"
    elif $HAS_AVX2; then
        CPU_BEST_VARIANT="haswell"
    else
        CPU_BEST_VARIANT="x64"
    fi

    # --- RAM ---
    local ram_total_mb=0
    local ram_avail_mb=0
    if command -v free &>/dev/null; then
        ram_total_mb=$(free -m | awk '/^Mem:/ {print $2}')
        ram_avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
    elif [ -f /proc/meminfo ]; then
        ram_total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
        ram_avail_mb=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo)
    fi

    # --- GPU (Vulkan) ---
    local vulkan_found=false
    local vulkan_vendor=""
    local vulkan_vram_mb=0
    local vulkan_device_name=""
    local vulkan_device_type=""

    if command -v vulkaninfo &>/dev/null; then
        local vk_summary
        vk_summary=$(vulkaninfo --summary 2>/dev/null)
        if [ -n "$vk_summary" ]; then
            vulkan_found=true
            # Extract device properties
            vulkan_device_name=$(echo "$vk_summary" | grep -m1 "deviceName" | sed 's/.*deviceName//' | sed 's/ *= *//' | sed 's/^[[:space:]]*//')
            vulkan_device_type=$(echo "$vk_summary" | grep -m1 "deviceType" | sed 's/.*deviceType//' | sed 's/ *= *//' | sed 's/^[[:space:]]*//')

            # For discrete GPUs, try full vulkaninfo for memory heaps
            # For integrated GPUs, there's no dedicated VRAM
            if echo "$vulkan_device_type" | grep -qi "DISCRETE"; then
                local vk_full
                vk_full=$(timeout 5 vulkaninfo 2>/dev/null)
                if [ -n "$vk_full" ]; then
                    # Try to find memory heap with device-local bit (flag = 1)
                    local heap_block
                    heap_block=$(echo "$vk_full" | grep -A5 "VkPhysicalDeviceMemoryProperties" | head -20)
                    local heap_size
                    heap_size=$(echo "$heap_block" | grep -oP 'size\s*=\s*\K[0-9]+' | head -1)
                    if [ -n "$heap_size" ]; then
                        vulkan_vram_mb=$((heap_size / 1024 / 1024))
                    fi
                fi
            fi

            # Vendor detection from deviceName
            case "$vulkan_device_name" in
                *"AMD"*|*"Radeon"*) vulkan_vendor="amd" ;;
                *"NVIDIA"*|*"GeForce"*|*"Quadro"*) vulkan_vendor="nvidia" ;;
                *"Intel"*|*"HD Graphics"*|*"Iris"*) vulkan_vendor="intel" ;;
                *) vulkan_vendor="unknown" ;;
            esac
        fi
    fi

    # --- Determine backend recommendation ---
    local rec_backend=""
    local rec_reason=""

    # Recommend Vulkan if available (even integrated, since llama.cpp can use it)
    if [ "$vulkan_found" = true ]; then
        if [ "$vulkan_vram_mb" -ge 4096 ]; then
            rec_backend="vulkan"
            rec_reason="GPU: $vulkan_device_name (${vulkan_vram_mb}MB VRAM)"
        elif [ "$vulkan_vram_mb" -ge 1024 ]; then
            rec_backend="vulkan"
            rec_reason="GPU: $vulkan_device_name (${vulkan_vram_mb}MB VRAM, может быть маловато)"
        elif echo "$vulkan_device_type" | grep -qi "INTEGRATED"; then
            # Integrated GPU — still offers Vulkan, but recommend CPU as safer
            if $HAS_AVX512 && $HAS_AVX512_VNNI; then
                rec_backend="cpu-avx512"
                rec_reason="AVX-512 + VNNI (CPU) — интегрированная GPU, но Vulkan доступен"
            elif $HAS_AVX2; then
                rec_backend="cpu-avx2"
                rec_reason="AVX2 (CPU) — интегрированная GPU, но Vulkan доступен"
            else
                rec_backend="cpu-base"
                rec_reason="Базовый CPU — интегрированная GPU, но Vulkan доступен"
            fi
        else
            rec_backend="vulkan"
            rec_reason="GPU: $vulkan_device_name (VRAM: ${vulkan_vram_mb}MB)"
        fi
    elif $HAS_AVX512 && $HAS_AVX512_VNNI; then
        rec_backend="cpu-avx512"
        rec_reason="AVX-512 + VNNI (CPU)"
    elif $HAS_AVX2; then
        rec_backend="cpu-avx2"
        rec_reason="AVX2 (CPU)"
    else
        rec_backend="cpu-base"
        rec_reason="Базовый CPU"
    fi

    # --- Export variables ---
    export HW_OS="linux"
    export HW_CPU_VENDOR="$cpu_vendor"
    export HW_CPU_PHYS_CORES="$phys_cores"
    export HW_CPU_VIRT_CORES="$virt_cores"
    export HW_CPU_FLAGS="$cpu_flags"
    export HW_HAS_AVX2=$HAS_AVX2
    export HW_HAS_AVX512=$HAS_AVX512
    export HW_HAS_AVX512_VNNI=$HAS_AVX512_VNNI
    export HW_HAS_AMX=$HAS_AMX
    export HW_CPU_BEST_VARIANT="$CPU_BEST_VARIANT"
    export HW_RAM_TOTAL_MB="$ram_total_mb"
    export HW_RAM_AVAIL_MB="$ram_avail_mb"
    export HW_VULKAN_FOUND=$vulkan_found
    export HW_VULKAN_VENDOR="$vulkan_vendor"
    export HW_VULKAN_VRAM_MB="$vulkan_vram_mb"
    export HW_VULKAN_DEVICE="$vulkan_device_name"
    export HW_REC_BACKEND="$rec_backend"
    export HW_REC_REASON="$rec_reason"
    export HW_THREADS="$phys_cores"
    if [ "$phys_cores" -lt 1 ]; then HW_THREADS=1; fi
}

# --- Helper: Estimate ngl for a given model size in MB ---
estimate_ngl() {
    local vram_mb=$1
    local model_mb=$2
    if [ -z "$model_mb" ] || [ "$model_mb" -eq 0 ]; then
        echo 99
        return
    fi
    # Rough estimate: each GPU layer uses ~ model_size * 1.2 bytes per token
    # Simple heuristic: leave 20% VRAM overhead
    local usable_vram=$((vram_mb * 80 / 100))
    # Each layer roughly uses model_size / 32 MB
    local per_layer=$((model_mb / 32))
    if [ "$per_layer" -lt 50 ]; then per_layer=50; fi
    local ngl=$((usable_vram / per_layer))
    if [ "$ngl" -gt 99 ]; then ngl=99; fi
    if [ "$ngl" -lt 1 ]; then ngl=1; fi
    echo "$ngl"
}

# --- Helper: Estimate context size ---
estimate_context() {
    local vram_mb=$1
    local ram_mb=$2
    if [ "$vram_mb" -ge 4096 ]; then
        echo 8192
    elif [ "$ram_mb" -ge 16000 ]; then
        echo 4096
    else
        echo 2048
    fi
}

# --- Helper: Get model size in MB from filename (with quantization awareness) ---
# Usage: get_model_size_mb <filename> [base_dir]
# Returns: estimated VRAM usage in MB considering quantization
get_model_size_mb() {
    local filename="$1"
    local base_dir="${2:-$SCRIPT_DIR/models}"

    # 1. Extract parameter size from filename (e.g., 7B, 14B, 0.5B, 32B)
    local size_str
    size_str=$(echo "$filename" | grep -oiP '(\d+(?:\.\d+)?)B' | head -1)
    local size_num

    if [ -n "$size_str" ]; then
        size_num=$(echo "$size_str" | grep -oiP '[\d.]+')
        local param_billions="$size_num"

        # 2. Detect quantization type from filename
        # Factor = bytes per parameter billion (e.g., 0.56 = 576 bytes/param ≈ 4.5 bits)
        local quant_factor=0.7
        case "$(echo "$filename" | tr '[:lower:]' '[:upper:]')" in
            *IQ4_NL*|*IQ4*) quant_factor=0.52 ;;
            *Q2_K*|*Q2_K_*|*IQ2_*) quant_factor=1.0 ;;
            *Q3_K_M*)      quant_factor=0.64 ;;
            *Q3_K_S*)      quant_factor=0.58 ;;
            *Q3_K*)        quant_factor=0.61 ;;
            *Q3_*)         quant_factor=0.59 ;;
            *Q4_0*|*Q4_1*) quant_factor=0.55 ;;
            *Q4_K_S*)      quant_factor=0.53 ;;
            *Q4_K_M*)      quant_factor=0.56 ;;
            *Q4_K_L*)      quant_factor=0.60 ;;
            *Q4_K*)        quant_factor=0.57 ;;
            *Q4_*)         quant_factor=0.55 ;;
            *Q5_0*|*Q5_1*) quant_factor=0.75 ;;
            *Q5_K_S*)      quant_factor=0.72 ;;
            *Q5_K_M*)      quant_factor=0.78 ;;
            *Q5_K*)        quant_factor=0.75 ;;
            *Q5_*)         quant_factor=0.76 ;;
            *Q6_K*)        quant_factor=0.85 ;;
            *Q6_*)         quant_factor=0.85 ;;
            *Q8_0*)        quant_factor=1.20 ;;
            *Q8_1*)        quant_factor=1.19 ;;
            *Q8_*)         quant_factor=1.20 ;;
            *Q2*)          quant_factor=1.0 ;; # generic fallback
            *Q3*)          quant_factor=0.60 ;;
            *Q4*)          quant_factor=0.56 ;;
            *Q5*)          quant_factor=0.75 ;;
            *Q6*)          quant_factor=0.85 ;;
            *Q8*)          quant_factor=1.20 ;;
            *F16*|*FP16*)  quant_factor=2.10 ;;
            *F32*|*FP32*)  quant_factor=4.20 ;;
            *)             quant_factor=0.70 ;; # Default: assume Q4-ish
        esac

        echo $(awk "BEGIN {printf \"%d\", $param_billions * 1024 * $quant_factor}")
    else
        # No parameter count in filename — try file size on disk
        local full_path="$base_dir/$filename"
        if [ -f "$full_path" ]; then
            local bytes
            bytes=$(stat -c%s "$full_path" 2>/dev/null || stat -f%z "$full_path" 2>/dev/null)
            echo $((bytes / 1024 / 1024))
        else
            echo 4000
        fi
    fi
}

# --- Helper: Get model parameter count from filename ---
# Returns: number of parameters (e.g., "7B", "0.5B", "32B")
get_model_params() {
    local filename="$1"
    echo "$filename" | grep -oiP '(\d+(?:\.\d+)?)B' | head -1 | grep -oiP '[\d.]+'
}

# --- Helper: Detect if model is Mixture-of-Experts (MoE) ---
# Returns: 0 if MoE, 1 if not
is_moe_model() {
    local filename="$1"
    local upper_fname
    upper_fname=$(echo "$filename" | tr '[:lower:]' '[:upper:]')

    # Check for MoE indicators in filename
    case "$upper_fname" in
        *MOE*|*MIXTRAL*|*8X*|*8x*|*DEEPSEEK-V2*|*DEEPSEEK-V3*|*DOLPHIN-MIX*|\
        *EXPERT*|*ROUTED*|*SPARSE*)
            return 0 ;;
        *)
            # Check for XxY pattern like 8x7B, 16x7B
            if echo "$upper_fname" | grep -qP '\d+X\d+[BM]'; then
                return 0
            fi
            return 1 ;;
    esac
}

# --- Helper: Get MoE expert count from filename ---
# Returns: number of experts (e.g., 8, 16, 32) or empty if dense
get_moe_expert_count() {
    local filename="$1"
    local upper_fname
    upper_fname=$(echo "$filename" | tr '[:lower:]' '[:upper:]')

    # Pattern like 8X7B, 16X7B, 32X1B
    local experts
    experts=$(echo "$upper_fname" | grep -oP '\d+X\d+[BM]' | head -1 | grep -oP '^\d+')
    if [ -n "$experts" ]; then
        echo "$experts"
    else
        # Fallback for models with -moe suffix but no XxY pattern
        # Common defaults: Mixtral = 8, DeepSeek = 64, others = 8
        case "$upper_fname" in
            *DEEPSEEK-MOE*|*DEEPSEEK-V2*MOE*|*DEEPSEEK-V3*MOE*)
                echo "64" ;;  # DeepSeek MoE uses 64 experts
            *)
                echo "8" ;;    # Default: assume 8 experts (Mixtral-style)
        esac
    fi
}

# --- Helper: Estimate effective model size for MoE (only active experts loaded) ---
# For MoE models: effective_size = param_size × (active_experts / total_experts)
# Returns: estimated VRAM in MB considering MoE expert activation
estimate_moe_vram_mb() {
    local filename="$1"
    local param_mb
    param_mb=$(get_model_size_mb "$filename")

    if ! is_moe_model "$filename"; then
        echo "$param_mb"
        return
    fi

    local experts
    experts=$(get_moe_expert_count "$filename")
    if [ -z "$experts" ]; then
        # Unknown expert count — assume 8 experts, 2 active (typical for Mixtral)
        experts=8
    fi

    # Typically 2 experts are active per token (top-2 routing)
    local active_ratio
    case "$experts" in
        4)  active_ratio=0.5 ;;   # 2/4 active
        8)  active_ratio=0.25 ;;   # 2/8 active
        16) active_ratio=0.125 ;;  # 2/16 active
        32) active_ratio=0.0625 ;; # 2/32 active
        *)  active_ratio=0.25 ;;   # default: assume 2/total
    esac

    # Effective VRAM = base_size × active_ratio + (total_experts × 0.1 for routing)
    local effective_mb
    effective_mb=$(awk "BEGIN {printf \"%d\", $param_mb * $active_ratio + ($param_mb / $experts) * 0.1 * $experts}")
    echo "$effective_mb"
}

# --- Helper: Get recommended ngl for MoE model ---
# For MoE models, recommends lower ngl to avoid VRAM pressure
estimate_moe_ngl() {
    local vram_mb=$1
    local model_mb=$2
    local experts=$3

    if [ -z "$experts" ] || [ "$experts" -eq 0 ]; then
        # Not a MoE model — use standard estimation
        echo $(estimate_ngl "$vram_mb" "$model_mb")
        return
    fi

    # For MoE models: use fewer GPU layers to leave room for expert caching
    # Rule: reserve ~30% of VRAM for active expert caching
    local usable_vram=$((vram_mb * 60 / 100))
    local per_layer=$((model_mb / 32))
    if [ "$per_layer" -lt 50 ]; then per_layer=50; fi
    local ngl=$((usable_vram / per_layer))

    if [ "$ngl" -gt 32 ]; then ngl=32; fi   # Cap MoE GPU layers at 32
    if [ "$ngl" -lt 1 ]; then ngl=1; fi
    echo "$ngl"
}

# --- Auto-detect CPU binary variant if needed ---
find_cpu_binary() {
    local desired_variant="$1"
    local bin_dir="$SCRIPT_DIR/bin/linux-cpu"
    case "$desired_variant" in
        sapphirerapids)
            for v in sapphirerapids zen4; do
                if [ -x "$bin_dir/llama-server" ]; then
                    echo "$bin_dir"
                    return
                fi
            done
            ;;
        haswell)
            if [ -x "$bin_dir/llama-server" ]; then
                echo "$bin_dir"
                return
            fi
            ;;
    esac
    # Fallback
    echo "$bin_dir"
}

detect_hardware
