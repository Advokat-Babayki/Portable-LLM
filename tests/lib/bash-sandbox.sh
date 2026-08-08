#!/bin/bash
# =====================================================
# bash-sandbox.sh — общая песочница для интеграционных
# тестов Lunix.sh (linux-cli-test.sh, linux-download-test.sh).
# Подключается: source "${ROOT}/tests/lib/bash-sandbox.sh"
#
# Даёт детерминированное окружение:
#   * PATH-стабы "железа" (lscpu/free/vulkaninfo/ss/xdg-open/timeout);
#   * стабы curl/wget/tar/stat для ветки скачивания;
#   * стабы бинарников llama-server / whisper-server, записывающие аргументы;
#   * копию Lunix.sh + lib/ в песочницу (install_launcher);
#   * запуск с изолированным XDG_CONFIG_HOME и stub-PATH (run_cli).
#
# Требует $ROOT (корень репозитория) — задаётся тестом ДО source.
# =====================================================

: "${ROOT:?bash-sandbox.sh: ROOT не задан}"

# Путь к папке со стабами PATH для песочницы.
stubdir() { echo "$1/bin-stub"; }

# Значение параметра из массива аргументов (по имени флага).
# Использование: value="$(arg_value --port "${A[@]}")"
arg_value() {
    local flag="$1"; shift
    local prev=""
    for a in "$@"; do
        if [ "$prev" = "$flag" ]; then echo "$a"; return; fi
        prev="$a"
    done
    echo ""
}

# -------------------------------------------------------------
# Стабы "железа" — детерминированный детект (cpu | vulkan)
# cpu:    RAM 128 GiB, 8 vCPU / 4 физических, без Vulkan
# vulkan: RAM 8 GiB, GPU 60 GiB VRAM (NVIDIA RTX 3080)
# -------------------------------------------------------------
make_hw_stubs() { # $1=sandbox, $2=profile: cpu|vulkan
    local sb="$1" hw="$2"
    local p; p="$(stubdir "$sb")"
    mkdir -p "$p" "$sb/lib" "$sb/models" "$sb/whisper/models" \
             "$sb/bin/linux-cpu" "$sb/bin/linux-vulkan" "$sb/whisper/bin/linux-cpu"

    # free — поддержка -m; RAM из профиля
    local ram
    [ "$hw" = "cpu" ] && ram=131072 || ram=8000
    cat > "$p/free" <<EOF
#!/bin/sh
if [ "\$1" = "-m" ]; then echo '              total        used        free      shared     buff/cache   available'; fi
echo 'Mem:       $ram       2000    $((ram-2000))       100      2000    4000'
echo 'Swap:      16000           0     16000'
EOF
    chmod +x "$p/free"

    # lscpu — 8 виртуальных, 4 физических ядра; AVX2 + AVX512 + AMX
    cat > "$p/lscpu" <<'EOF'
#!/bin/sh
cat <<'OUT'
Architecture:        x86_64
CPU op-mode(s):      32-bit, 64-bit
Byte Order:          Little Endian
CPU(s):              8
Thread(s) per core:  2
Core(s) per socket:  4
Socket(s):           1
Vendor ID:           GenuineIntel
Flags:               avx2 avx512f avx512_vnni amx
OUT
EOF
    chmod +x "$p/lscpu"

    # vulkaninfo — нет (cpu) или есть 60 GiB VRAM (vulkan)
    if [ "$hw" = "vulkan" ]; then
        cat > "$p/vulkaninfo" <<'EOF'
#!/bin/sh
if [ "$1" = "--summary" ]; then
  echo 'deviceName        = NVIDIA GeForce RTX 3080'
  echo 'deviceType        = DISCRETE_GPU'
  exit 0
fi
echo 'VkPhysicalDeviceMemoryProperties'
echo '  size     = 64424509440'
echo '  TYPE     = 1'
echo '  flags    = 1'
exit 0
EOF
        chmod +x "$p/vulkaninfo"
        # timeout — пропускаем лимит, зовём vulkaninfo напрямую
        cat > "$p/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
        chmod +x "$p/timeout"
    fi

    # ss — всегда "не занято": find_free_port отдаёт базовый порт
    cat > "$p/ss" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$p/ss"

    # xdg-open — браузер в тесте не открываем
    cat > "$p/xdg-open" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$p/xdg-open"
}

# -------------------------------------------------------------
# Стабы скачивания: curl/wget/tar/stat
#   curl/wget — пишут "архив", логируют аргументы в $DL_RECORD
#   tar        — "распаковывает", создавая ключевые файлы
#   stat       — всегда большой размер (если не STUB_STAT_SIZE)
# Управление ошибками через окружение:
#   STUB_CURL_FAIL, STUB_TAR_FAIL, STUB_TAR_NOKEY, STUB_STAT_SIZE
# -------------------------------------------------------------
make_dl_stubs() { # $1=sandbox
    local sb="$1"
    local p; p="$(stubdir "$sb")"

    cat > "$p/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${DL_RECORD:-/dev/null}"
[ -n "${STUB_CURL_FAIL:-}" ] && { echo "curl: network error" >&2; exit 7; }
out=""
next=""
for a in "$@"; do
    if [ "$next" = "-o" ]; then out="$a"; next=""; continue; fi
    case "$a" in -o) next="-o";; esac
done
[ -n "$out" ] && printf 'fake-archive-content\n' > "$out"
exit 0
EOF
    chmod +x "$p/curl"

    cat > "$p/wget" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${DL_RECORD:-/dev/null}"
[ -n "${STUB_CURL_FAIL:-}" ] && { echo "wget: network error" >&2; exit 7; }
out=""
next=""
for a in "$@"; do
    if [ "$next" = "-O" ]; then out="$a"; next=""; continue; fi
    case "$a" in -O) next="-O";; esac
done
[ -n "$out" ] && printf 'fake-archive-content\n' > "$out"
exit 0
EOF
    chmod +x "$p/wget"

    cat > "$p/tar" <<'EOF'
#!/bin/sh
[ -n "${STUB_TAR_FAIL:-}" ] && { echo "tar: extract error" >&2; exit 2; }
dest=""
next=""
for a in "$@"; do
    if [ "$next" = "-C" ]; then dest="$a"; next=""; continue; fi
    case "$a" in -C) next="-C";; esac
done
if [ -z "${STUB_TAR_NOKEY:-}" ] && [ -n "$dest" ]; then
    mkdir -p "$dest"
    printf '#!/bin/sh\nexit 0\n' > "$dest/llama-server"
    printf '#!/bin/sh\nexit 0\n' > "$dest/whisper-server"
    chmod +x "$dest/llama-server" "$dest/whisper-server"
fi
exit 0
EOF
    chmod +x "$p/tar"

    cat > "$p/stat" <<'EOF'
#!/bin/sh
echo "${STUB_STAT_SIZE:-2000000}"
exit 0
EOF
    chmod +x "$p/stat"
}

# -------------------------------------------------------------
# Стабы бинарников: записывают аргументы и выходят
# -------------------------------------------------------------
make_bin_stubs() { # $1=sandbox
    local sb="$1"
    local stub='#!/bin/sh'$'\n''printf "%s\n" "$@" > "${LLM_STUB_RECORD:-/dev/null}"'$'\n''exit 0'
    printf '%s' "$stub" > "$sb/bin/linux-cpu/llama-server"
    cp "$sb/bin/linux-cpu/llama-server" "$sb/bin/linux-vulkan/llama-server"
    sed 's/LLM_STUB_RECORD/WHISPER_STUB_RECORD/' "$sb/bin/linux-cpu/llama-server" > "$sb/whisper/bin/linux-cpu/whisper-server"
    chmod +x "$sb/bin/linux-cpu/llama-server" "$sb/bin/linux-vulkan/llama-server" \
             "$sb/whisper/bin/linux-cpu/whisper-server"
}

# -------------------------------------------------------------
# Лишущая копия Lunix.sh + lib/ (см. AGENTS.md: cp -r lib $sb/lib
# создаёт вложенный lib/lib — поэтому сначала rm)
# -------------------------------------------------------------
install_launcher() { # $1=sandbox
    cp "$ROOT/Lunix.sh" "$1/Lunix.sh"
    chmod +x "$1/Lunix.sh"
    rm -rf "$1/lib"
    cp -r "$ROOT/lib" "$1/"
}

# -------------------------------------------------------------
# Запуск Lunix.sh: стабы в PATH впереди, изолированный XDG_CONFIG_HOME
# -------------------------------------------------------------
run_cli() { # $1=sandbox, ...args — запуск Lunix.sh
    local sb="$1"; shift
    env PATH="$(stubdir "$sb"):$PATH" XDG_CONFIG_HOME="$sb/xdg" \
        "$sb/Lunix.sh" "$@"
}
