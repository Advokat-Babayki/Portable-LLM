#!/bin/bash
# =====================================================
# common.sh — Shared functions for Lunix.sh
# NOTE: Expects SCRIPT_DIR to be defined by caller (Lunix.sh)
# =====================================================

# --- Find a free port starting from base ---
find_free_port() {
    local base_port=$1
    local port=$base_port
    while ss -tuln 2>/dev/null | grep -q ":$port " || netstat -tuln 2>/dev/null | grep -q ":$port "; do
        ((port++))
        if [ "$port" -gt 65535 ]; then
            echo "$base_port"
            return
        fi
    done
    echo "$port"
}

# --- Display hardware info summary ---
print_hw_info() {
    echo "==================================================="
    echo "  Система: $HW_OS"
    echo "  CPU: $HW_CPU_VENDOR | $HW_CPU_VIRT_CORES потоков | $HW_RAM_TOTAL_MB MB RAM"
    echo "  AVX2: $HW_HAS_AVX2 | AVX-512: $HW_HAS_AVX512"
    if [ "$HW_VULKAN_FOUND" = true ]; then
        echo "  GPU: $HW_VULKAN_DEVICE | $HW_VULKAN_VENDOR | ${HW_VULKAN_VRAM_MB}MB VRAM"
    else
        echo "  GPU: Не обнаружен Vulkan"
    fi
    echo "  Рекомендация: $HW_REC_REASON"
    echo "==================================================="
}

# --- Run server with crash logging ---
run_with_crash_log() {
    local mode=$1      # "llm" | "whisper"
    local backend=$2   # "vulkan" | "cpu"
    local bin_path=$3
    shift 3
    local args=("$@")

    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local log_prefix="logs/run_${timestamp}_${mode}"
    local full_log="${log_prefix}.log"
    local ready=false

    mkdir -p logs

    echo "[*] Запуск: $bin_path"
    echo "[*] Папка для логов: logs/"

    # Run binary, capture output to log + stdout (without losing PID)
    "$bin_path" "${args[@]}" 2>&1 | tee "$full_log"
    local exit_code=${PIPESTATUS[0]}

    # Check for crash — exclude normal shutdown codes:
    # 130 = SIGINT (Ctrl+C), 143 = SIGTERM, 124 = timeout command
    if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 124 ] && [ "$exit_code" -ne 130 ] && [ "$exit_code" -ne 143 ]; then
        # Create crash report
        local crash_file="logs/crash_$(date '+%Y-%m-%d_%H-%M-%S')_${mode}.log"
        {
            echo "=== CRASH REPORT ==="
            echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Backend: $backend"
            echo "Mode: $mode"
            echo "Exit code: $exit_code"
            echo "Args: $bin_path ${args[*]}"
            echo "HW_OS: $HW_OS"
            echo "CPU: $HW_CPU_VENDOR ($HW_CPU_VIRT_CORES threads)"
            echo "RAM: ${HW_RAM_TOTAL_MB}MB total"
            if [ "$HW_VULKAN_FOUND" = true ]; then
                echo "GPU: $HW_VULKAN_DEVICE (${HW_VULKAN_VRAM_MB}MB)"
            fi
            echo ""
            echo "=== STDOUT/STDERR ==="
            cat "$full_log"
            echo "=== END ==="
        } > "$crash_file"
        echo ""
        echo "[!] КРАШ! Отчёт сохранён: $crash_file"
    fi

    rm -f "$full_log"
    return $exit_code
}
