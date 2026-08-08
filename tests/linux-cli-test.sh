#!/bin/bash
# =====================================================
# linux-cli-test.sh — интеграционный тест CLI-режима Lunix.sh
# Полностью детерминирован:
#   * PATH-стабы (lscpu/free/vulkaninfo/timeout/ss) задают "железо";
#   * стабы llama-server / whisper-server записывают свои аргументы;
#   * проверяются: коды выхода CLI-парсера, вектор аргументов
#     (ctx/ngl/batch/ub/alias/host/port), ветка mlock, MoE, вызов
#     opencode_update.sh, маршрут Whisper.
# Репозиторий не трогается: работаем в песочнице $WORK.
# Запуск: bash tests/linux-cli-test.sh  (exit 0 при успехе)
# =====================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0

assert_eq() { # $1 expected, $2 actual, $3 name
    if [ "$1" != "$2" ]; then
        FAILURES=$((FAILURES+1))
        echo "FAIL: $3 — ожидал '$1', получил '$2'"
    else
        echo "OK:   $3 = '$2'"
    fi
}

assert_true() { # $1 cond(0), $2 name
    if [ "$1" -ne 0 ]; then
        FAILURES=$((FAILURES+1))
        echo "FAIL: $2"
    else
        echo "OK:   $2"
    fi
}

stubdir() { echo "$1/bin-stub"; }

# Значение параметра из массива аргументов (по имени флага).
# Использование: value="$(arg_value --port ${A[@]})"
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
# Стабы "железа" — детерминированный детект
# -------------------------------------------------------------
make_hw_stubs() { # $1=sandbox, $2=profile: cpu|vulkan
    local sb="$1" hw="$2"
    local p; p="$(stubdir "$sb")"
    mkdir -p "$p" "$sb/lib" "$sb/models" "$sb/whisper/models" \
             "$sb/bin/linux-cpu" "$sb/bin/linux-vulkan" "$sb/whisper/bin/linux-cpu"

    # free — поддержка -m; RAM из профиля (cpu: 128GiB, vulkan: 8GiB)
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

# Лишущая копия Lunix.sh + lib/
install_launcher() { # $1=sandbox
    cp "$ROOT/Lunix.sh" "$1/Lunix.sh"
    chmod +x "$1/Lunix.sh"
    rm -rf "$1/lib"
    cp -r "$ROOT/lib" "$1/"
}

run_cli() { # $1=sandbox, ...args — запуск Lunix.sh: стабы в PATH впереди
    local sb="$1"; shift
    env PATH="$(stubdir "$sb"):$PATH" XDG_CONFIG_HOME="$sb/xdg" \
        "$sb/Lunix.sh" "$@"
}

# -------------------------------------------------------------
echo "=== 1. CLI-парсер: ошибки и коды выхода ==="
SB1="$WORK/s1"
make_hw_stubs "$SB1" cpu; make_bin_stubs "$SB1"; install_launcher "$SB1"

run_cli "$SB1" --model >/dev/null 2>&1;            assert_eq 1 "$?" "1a: --model без значения → exit 1"
run_cli "$SB1" --backend >/dev/null 2>&1;          assert_eq 1 "$?" "1b: --backend без значения → exit 1"
run_cli "$SB1" --nope >/dev/null 2>&1;             assert_eq 1 "$?" "1c: неизвестный флаг → exit 1"
out="$(run_cli "$SB1" --no-ui 2>&1)"; rc=$?
assert_eq 1 "$rc" "1d: --no-ui без --model → exit 1"
assert_true "$(echo "$out" | grep -q 'Укажите'; echo $?)" "1d: сообщение об ошибке"
run_cli "$SB1" --help >/dev/null 2>&1;             assert_eq 0 "$?" "1e: --help → exit 0"

echo ""
echo "=== 2. CPU-запуск: mlock при RAM > 3×модель ==="
SB2="$(mktemp -d "$WORK/s2.XXXX")"; make_hw_stubs "$SB2" cpu
printf 'fakegguf' > "$SB2/models/test-7b-q4_k_m.gguf"
make_bin_stubs "$SB2"; install_launcher "$SB2"
LLM_STUB_RECORD="$WORK/cpu.args" run_cli "$SB2" --silent --model test-7b-q4_k_m.gguf --backend cpu >/dev/null 2>&1
assert_true "$([ -f "$WORK/cpu.args" ]; echo $?)" "2: стаб записал аргументы"
A=(); mapfile -t A < "$WORK/cpu.args"
assert_eq "-m"      "${A[0]-}"                       "2: первый аргумент -m"
assert_eq "$SB2/models/test-7b-q4_k_m.gguf" "${A[1]-}" "2: путь модели"
assert_eq "mlock"   "$(arg_value --load-mode "${A[@]}")"     "2: --load-mode mlock (RAM 128G/модель 4G)"
assert_eq "0"       "$(arg_value -ngl "${A[@]}")"            "2: ngl=0 (cpu)"
assert_eq "256"     "$(arg_value -b "${A[@]}")"              "2: batch=256 (cpu)"
assert_eq "8080"    "$(arg_value --port "${A[@]}")"          "2: порт 8080"
assert_eq "test-7b-q4_k_m.gguf" "$(arg_value --alias "${A[@]}")" "2: alias"

echo ""
echo "=== 3. Vulkan-запуск: ngl=99, batch/ub=512 ==="
SB3="$(mktemp -d "$WORK/s3.XXXX")"; make_hw_stubs "$SB3" vulkan
printf 'fake' > "$SB3/models/test-7b-q4_k_m.gguf"
make_bin_stubs "$SB3"; install_launcher "$SB3"
LLM_STUB_RECORD="$WORK/vk.args" run_cli "$SB3" --silent --model test-7b-q4_k_m.gguf --backend vulkan >/dev/null 2>&1
A=(); mapfile -t A < "$WORK/vk.args"
assert_eq "99"      "$(arg_value -ngl "${A[@]}")"     "3: ngl=99 (VRAM 60GiB)"
assert_eq "512"     "$(arg_value -b "${A[@]}")"       "3: batch=512 (vulkan)"
assert_eq "512"     "$(arg_value -ub "${A[@]}")"      "3: ub=512"
assert_eq "8080"    "$(arg_value --port "${A[@]}")"   "3: порт 8080"
assert_eq "test-7b-q4_k_m.gguf" "$(arg_value --alias "${A[@]}")" "3: alias"

echo ""
echo "=== 4. MoE: mixtral-8x7b → cap ngl=32 ==="
SB4="$(mktemp -d "$WORK/s4.XXXX")"; make_hw_stubs "$SB4" vulkan
printf 'fake' > "$SB4/models/mixtral-8x7b-instruct-q4_k_m.gguf"
make_bin_stubs "$SB4"; install_launcher "$SB4"
LLM_STUB_RECORD="$WORK/moe.args" run_cli "$SB4" --silent --model mixtral-8x7b-instruct-q4_k_m.gguf --backend vulkan >/dev/null 2>&1
A=(); mapfile -t A < "$WORK/moe.args"
assert_eq "32" "$(arg_value -ngl "${A[@]}")"                              "4: MoE ngl=32 (cap)"
assert_eq "mixtral-8x7b-instruct-q4_k_m.gguf" "$(arg_value --alias "${A[@]}")" "4: alias"

echo ""
echo "=== 5. opencode_update.sh вызывается из run_llm_server ==="
SB5="$(mktemp -d "$WORK/s5.XXXX")"; make_hw_stubs "$SB5" cpu
printf 'fake' > "$SB5/models/test-1b.gguf"
make_bin_stubs "$SB5"; install_launcher "$SB5"
LLM_STUB_RECORD="$WORK/x.args" run_cli "$SB5" --silent --model test-1b.gguf >/dev/null 2>&1
assert_true "$( [ -f "$SB5/xdg/opencode/opencode.json" ]; echo $? )" "5: opencode.json создан (XDG_CONFIG_HOME)"
OC="$SB5/xdg/opencode/opencode.json"
if [ -f "$OC" ]; then
    assert_true "$(grep -q 'baseURL' "$OC"; echo $?)" "5: baseURL записан"
    assert_true "$(grep -q 'test-1b.gguf' "$OC"; echo $?)" "5: opencode содержит модель"
fi

echo ""
echo "=== 6. Whisper: --public ./.., порт 8081 ==="
SB6="$(mktemp -d "$WORK/s6.XXXXXX")"; make_hw_stubs "$SB6" cpu
printf 'fake' > "$SB6/whisper/models/whisper-tiny.bin"
make_bin_stubs "$SB6"; install_launcher "$SB6"
WHISPER_STUB_RECORD="$WORK/wh.args" run_cli "$SB6" --silent --model whisper-tiny.bin >/dev/null 2>&1
assert_true "$([ -f "$WORK/wh.args" ]; echo $?)" "6: whisper стаб вызван"
W=(); mapfile -t W < "$WORK/wh.args"
assert_eq "8081" "$(arg_value --port "${W[@]}")" "6: порт 8081"
assert_eq "../../" "$(arg_value --public "${W[@]}")" "6: --public ../../"

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "FAILURES: $FAILURES"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0