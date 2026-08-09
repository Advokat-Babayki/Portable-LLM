#!/bin/bash
# =====================================================
# linux-unit.sh — Unit-тесты Linux-ветки (lib/*.sh)
# Цель: паритет с Windows-тестами (tests/windows-unit.ps1):
# те же формулы/таблицы должны давать те же значения.
# Запуск: bash tests/linux-unit.sh   (exit 0 при успехе, иначе 1)
# =====================================================
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$ROOT"
export SCRIPT_DIR

source "$ROOT/tests/lib/bash-assert.sh"

echo "=== Загрузка lib/ ==="
source "$ROOT/lib/detect_hw.sh"
source "$ROOT/lib/common.sh"

echo "=== Get-ModelSizeMB (паритет с PS-факторами, общая таблица quant-factors.tsv) ==="
assert_eq 4014 "$(get_model_size_mb 'qwen2.5-7b-instruct-q4_k_m.gguf')"  'qwen2.5-7b Q4_K_M'
assert_eq 7004 "$(get_model_size_mb 'gemma-4-12B-it-qat-UD-Q4_K_XL.gguf')" 'gemma-4-12B Q4_K_XL'
assert_eq 19661 "$(get_model_size_mb 'qwen2.5-32B-instruct-q4_k_l.gguf')" 'qwen2.5-32B Q4_K_L'
assert_eq 1966 "$(get_model_size_mb 'test-q3_k_m-3b.gguf')"  '3B Q3_K_M'
assert_eq 6451 "$(get_model_size_mb 'test-f16-3b.gguf')"     '3B F16'
assert_eq 3686 "$(get_model_size_mb 'test-q8_0-3b.gguf')"    '3B Q8_0'
assert_eq 2212 "$(get_model_size_mb 'test-q5_k_s-3b.gguf')"  '3B Q5_K_S'
assert_eq 1690 "$(get_model_size_mb 'test-q4_0-3b.gguf')"    '3B Q4_0'
assert_eq 717 "$(get_model_size_mb 'test-1b.gguf')"          '1B без квантизации'

echo "=== Estimate-Context / Estimate-NGL (fallback-эвристика не менялась) ==="
assert_eq 8192 "$(estimate_context 4096 1000)"   'Context: VRAM>=4096'
assert_eq 4096 "$(estimate_context 0 16000)"     'Context: RAM>=16G'
assert_eq 2048 "$(estimate_context 0 8000)"      'Context: RAM<16G'
assert_eq 1 "$(estimate_ngl 0 4014)"             'NGL: без VRAM'
assert_eq 52 "$(estimate_ngl 8192 4014)"         'NGL: 8G VRAM / 4G модель'
assert_eq 99 "$(estimate_ngl 8192 100)"          'NGL: кап 99'

echo "=== GGUF-парсер (синтетический мини-GGUF, паритет с PS-тестом) ==="
TMP_GGUF="$(mktemp /tmp/llm_gguf_test_XXXXXX.gguf)"
# Тот же байт-в-байт файл, что в windows-unit.ps1 (qwen2: 28L/4KV/128hd, ctx 32768)
base64 -d > "$TMP_GGUF" <<'GGUF_B64'
R0dVRgMAAAAMAAAAAAAAAAcAAAAAAAAAFAAAAAAAAABnZW5lcmFsLmFyY2hpdGVjdHVyZQgAAAAFAAAAAAAAAHF3ZW4yFAAAAAAAAABxd2VuMi5jb250ZXh0X2xlbmd0aAQAAAAAgAAAFgAAAAAAAABxd2VuMi5lbWJlZGRpbmdfbGVuZ3RoBAAAAAAOAAARAAAAAAAAAHF3ZW4yLmJsb2NrX2NvdW50BAAAABwAAAAaAAAAAAAAAHF3ZW4yLmF0dGVudGlvbi5oZWFkX2NvdW50BAAAABwAAAAdAAAAAAAAAHF3ZW4yLmF0dGVudGlvbi5oZWFkX2NvdW50X2t2BAAAAAQAAAAYAAAAAAAAAHF3ZW4yLmF0dGVudGlvbi5oZWFkX2RpbQQAAACAAAAAEAAAAAAAAABxd2VuMi52b2NhYl9zaXplBAAAAIBRAgAVAAAAAAAAAHRva2VuaXplci5nZ21sLnRva2VucwkAAAAIAAAAAwAAAAAAAAAFAAAAAAAAAGhlbGxvBQAAAAAAAAB3b3JsZAEAAAAAAAAAIQ==
GGUF_B64
parse_gguf_meta "$TMP_GGUF"
assert_eq 0 "$?" "GGUF: парсинг успешен"
assert_eq 32768 "$gguf_ctx"    'GGUF: context_length = 32768'
assert_eq 28    "$gguf_layer"  'GGUF: block_count = 28'
assert_eq 4     "$gguf_nkv"    'GGUF: head_count_kv = 4'
assert_eq 128   "$gguf_head_dim" 'GGUF: head_dim = 128'
assert_eq "qwen2" "$gguf_arch"  'GGUF: architecture = qwen2'
echo "GGUF тест-файл: $TMP_GGUF"

echo "=== GGUF: регрессия раннего выхода (большой tokenizer, HANG-тест) ==="
BIG_GGUF="$(mktemp /tmp/llm_gguf_big_XXXXXX.gguf)"
oct() { printf '%03o' "$1"; }
u32le() { local v=$1; printf "\\$(oct $(( v & 255 )))\\$(oct $(( (v >> 8) & 255 )))\\$(oct $(( (v >> 16) & 255 )))\\$(oct $(( (v >> 24) & 255 )))"; }
u64le() { local v=$1
    printf "\\$(oct $(( v & 255 )))\\$(oct $(( (v >> 8) & 255 )))\\$(oct $(( (v >> 16) & 255 )))\\$(oct $(( (v >> 24) & 255 )))\\$(oct $(( (v >> 32) & 255 )))\\$(oct $(( (v >> 40) & 255 )))\\$(oct $(( (v >> 48) & 255 )))\\$(oct $(( (v >> 56) & 255 )))"; }
put_key() { local k="$1"; u64le "${#k}"; printf '%s' "$k"; }
put_strkv() { local k="$1" v="$2"; put_key "$k"; u32le 8; u64le "${#v}"; printf '%s' "$v"; }
put_u32kv() { local k="$1" v="$2"; put_key "$k"; u32le 4; u32le "$v"; }
{
    printf 'GGUF'
    u32le 3; u64le 0; u64le 7
    put_strkv general.architecture qwen2
    put_u32kv qwen2.block_count 36
    put_u32kv qwen2.context_length 32768
    put_u32kv qwen2.embedding_length 2048
    put_u32kv qwen2.attention.head_count 16
    put_u32kv qwen2.attention.head_count_kv 2
    put_key tokenizer.ggml.tokens; u32le 9; u32le 8; u64le 200000   # 200k пустых строк
} > "$BIG_GGUF"
dd if=/dev/zero bs=1600000 count=1 2>/dev/null >> "$BIG_GGUF"
BIG_RES="$(timeout 20 bash -c '. "$0"; parse_gguf_meta "$1" && echo "ctx=$gguf_ctx layer=$gguf_layer nkv=$gguf_nkv hdim=$gguf_head_dim" || echo FAIL' "$ROOT/lib/detect_hw.sh" "$BIG_GGUF" 2>/dev/null)"
assert_eq 0 "$?" "GGUF-big: парсинг завершился в пределах таймаута (не завис)"
assert_eq "ctx=32768 layer=36 nkv=2 hdim=128" "$BIG_RES" "GGUF-big: метаданные до tokenizer.* (без чтения 200k строк)"
rm -f "$BIG_GGUF"

echo "=== estimate_context_model (паритет с Get-RecommendedContext PS) ==="
assert_eq 13385 "$(estimate_context_model "$TMP_GGUF" cpu 3000 1500 0)"      'Rec-Ctx: cpu free3000/model1500'
assert_eq 32768 "$(estimate_context_model "$TMP_GGUF" vulkan 3000 1500 4096)" 'Rec-Ctx: vulkan vram4096>=model1500 → native cap'
assert_eq 32768 "$(estimate_context_model "$TMP_GGUF" cpu 8192 4014 0)"      'Rec-Ctx: cpu free8192/model4014'
assert_eq 256   "$(estimate_context_model "$TMP_GGUF" cpu 4096 4014 0)"      'Rec-Ctx: cpu free4096<model4014 -> min 256'
assert_eq 2048  "$(estimate_context_model "" cpu 4096 1000 0)"               'Rec-Ctx: пустой файл -> fallback RAM<16G'
assert_eq 8192  "$(estimate_context_model /nonexistent.gguf cpu 4096 1000 4096)" 'Rec-Ctx: нет GGUF+VRAM4096 -> fallback VRAM'
rm -f "$TMP_GGUF"

echo "=== MoE ==="
assert_true "$(is_moe_model 'mixtral-8x7b-instruct-q4_k_m.gguf' && echo true || echo false)" 'MoE: Mixtral-8x7B'
assert_true "$(is_moe_model 'deepseek-v2-lite-16b-moe-q4_k_m.gguf' && echo true || echo false)" 'MoE: DeepSeek-V2'
assert_true "$(is_moe_model 'qwen2.5-7b-instruct-q4_k_m.gguf' && echo false || echo true)" 'MoE: qwen2.5 не MoE'
assert_eq 8  "$(get_moe_expert_count 'mixtral-8x7b-instruct-q4_k_m.gguf')" 'MoE: 8 экспертов'
assert_eq 64 "$(get_moe_expert_count 'deepseek-v2-lite-16b-moe-q4_k_m.gguf')" 'MoE: DeepSeek 64'
assert_eq 32 "$(estimate_moe_ngl 8192 1404 8)" 'MoE NGL: кап 32'

echo "=== find_free_port (занятый порт) ==="
python3 -m http.server 18431 --bind 127.0.0.1 >/dev/null 2>&1 &
SRV_PID=$!
sleep 1
FREE="$(find_free_port 18431)"
kill $SRV_PID 2>/dev/null; wait $SRV_PID 2>/dev/null
assert_eq 18432 "$FREE" 'find_free_port: занятый 18431 -> 18432'
assert_eq 18440 "$(find_free_port 18440)" 'find_free_port: свободный 18440'

echo "=== run_with_crash_log (краш-детект, как PS-тест) ==="
# exit 5 → должен появиться crash-отчёт
run_with_crash_log "TEST_CRASH" "cpu" "/bin/sh" "-c" "exit 5" >/dev/null 2>&1
CRASH_FILES=$(ls "$ROOT/logs"/crash_*_TEST_CRASH.log 2>/dev/null | wc -l)
assert_eq 1 "$CRASH_FILES" 'run_with_crash_log: краш-отчёт создан (exit 5)'
# exit 0 → отчёта быть не должно
run_with_crash_log "TEST_OK" "cpu" "/bin/sh" "-c" "exit 0" >/dev/null 2>&1
OK_FILES=$(ls "$ROOT/logs"/crash_*_TEST_OK.log 2>/dev/null | wc -l)
assert_eq 0 "$OK_FILES" 'run_with_crash_log: нет отчёта при exit 0'
rm -f "$ROOT/logs"/crash_*_TEST_CRASH.log "$ROOT/logs"/crash_*_TEST_OK.log

test_done
