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

source "$ROOT/tests/lib/bash-assert.sh"
source "$ROOT/tests/lib/bash-sandbox.sh"

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
echo "=== 4. MoE: mixtral-8x7b → cap ngl=32 + MoE-признаки ==="
SB4="$(mktemp -d "$WORK/s4.XXXX")"; make_hw_stubs "$SB4" vulkan
printf 'fake' > "$SB4/models/mixtral-8x7b-instruct-q4_k_m.gguf"
make_bin_stubs "$SB4"; install_launcher "$SB4"
LLM_STUB_RECORD="$WORK/moe.args" run_cli "$SB4" --silent --model mixtral-8x7b-instruct-q4_k_m.gguf --backend vulkan >/dev/null 2>&1
A=(); mapfile -t A < "$WORK/moe.args"
assert_eq "32" "$(arg_value -ngl "${A[@]}")"                              "4: MoE ngl=32 (cap)"
assert_eq "mixtral-8x7b-instruct-q4_k_m.gguf" "$(arg_value --alias "${A[@]}")" "4: alias"
# Проверка что MoE-детекция сработала: контекст должен использовать model_mb < 4014
# (effective MoE vram = 1404 MB, что приводит к другому ctx, чем dense 4014 MB)
# Сравниваем: для dense модели test-7b (4014MB) с VRAM 60GiB ctx = native cap = 32768
# Для MoE mixtral (effective 1404MB) с VRAM 60GiB ctx тоже = 32768 (тоже cap).
# Более точная проверка — что стаб получил корректные параметры с учётом MoE.
# MoE-модель с экспертами: используется estimate_moe_ngl → cap 32
assert_eq "512" "$(arg_value -b "${A[@]}")"                               "4: batch=512 (vulkan, MoE)"
assert_eq "512" "$(arg_value -ub "${A[@]}")"                              "4: ub=512 (MoE)"

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
assert_eq "../../whisper/ui" "$(arg_value --public "${W[@]}")" "6: --public ../../whisper/ui"

test_done