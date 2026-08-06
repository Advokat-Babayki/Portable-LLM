#!/bin/bash
# =====================================================
# common.sh — Shared functions for Lunix.sh
# NOTE: Expects SCRIPT_DIR to be defined by caller (Lunix.sh)
# =====================================================

# --- Ensure binaries are executable ---
ensure_executables() {
    local dirs=("bin/linux-cpu" "bin/linux-vulkan" "whisper/bin/linux-cpu" "whisper/bin/linux-vulkan")
    for dir in "${dirs[@]}"; do
        if [ -d "${SCRIPT_DIR}/${dir}" ]; then
            chmod +x "${SCRIPT_DIR}/${dir}"/* 2>/dev/null
            chmod +x "${SCRIPT_DIR}/${dir}/llama-server" "${SCRIPT_DIR}/${dir}/whisper-server" 2>/dev/null
        fi
    done
}

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

# --- Check if a process is listening ---
wait_for_server_ready() {
    local port=$1
    local max_wait=${2:-60}
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if curl -sf "http://127.0.0.1:$port" >/dev/null 2>&1; then
            return 0
        fi
        if python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$port', timeout=2)" 2>/dev/null; then
            return 0
        fi
        sleep 2
        ((waited+=2))
    done
    return 1
}

# --- Scan models in a directory ---
scan_models() {
    local dir=$1
    local extensions=("gguf" "bin")
    local files=()

    if [ ! -d "$dir" ]; then
        echo ""
        return
    fi

    for ext in "${extensions[@]}"; do
        while IFS= read -r -d '' f; do
            basename "$f"
        done < <(find "$dir" -maxdepth 1 -type f -name "*.$ext" -print0 2>/dev/null)
    done
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

# --- Select model interactively ---
select_model() {
    local dir=$1
    local prompt=$2
    shift 2

    mapfile -t MODELS < <(scan_models "$dir")

    if [ ${#MODELS[@]} -eq 0 ]; then
        echo "[!] ${prompt} папка пуста: $dir" >&2
        echo "Положите .gguf/.bin файлы в эту папку." >&2
        read -p "Нажмите Enter для возврата..." >&2
        return 1
    fi

    echo "Доступные модели:" >&2
    for i in "${!MODELS[@]}"; do
        local size_mb=$(get_model_size_mb "${MODELS[$i]}" "$dir")
        echo "  $((i+1))) ${MODELS[$i]} (~$size_mb MB)" >&2
    done
    echo "  b) Назад" >&2
    echo "" >&2
    read -p "Выберите модель (1-${#MODELS[@]}): " choice >&2

    if [[ "$choice" == "b" || "$choice" == "B" ]]; then
        return 1
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#MODELS[@]}" ]; then
        echo "Неверный выбор!" >&2
        sleep 1
        return 1
    fi

    echo "${MODELS[$((choice-1))]}"
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
