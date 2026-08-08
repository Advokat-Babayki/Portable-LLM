#!/bin/bash
# =====================================================
# opencode-unit.sh — Unit-тесты lib/opencode_update.sh
# Проверяет манипуляции с глобальным opencode-конфигом:
# создание, swap-блока llama-local, вставка провайдера,
# защита от однострочных/битых конфигов, резервные копии.
# Каждый кейс работает в отдельном $XDG_CONFIG_HOME (temp),
# валидность JSON проверяется jq (fallback: python3).
# Запуск: bash tests/opencode-unit.sh  (exit 0 при успехе)
# =====================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE="$ROOT/lib/opencode_update.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0

# --- helpers -----------------------------------------------------------
assert_eq() { # $1 expected, $2 actual, $3 name
    if [ "$1" != "$2" ]; then
        FAILURES=$((FAILURES+1))
        echo "FAIL: $3 — ожидал '$1', получил '$2'"
    else
        echo "OK:   $3 = '$2'"
    fi
}

assert_true() { # $1 cond(0/ok), $2 name
    if [ "$1" -eq 0 ]; then
        echo "OK:   $2"
    else
        FAILURES=$((FAILURES+1))
        echo "FAIL: $2"
    fi
}

# config_is_valid: exit 0 если файл — валидный JSON и содержит llama-local
config_is_valid() {
    local f="$1" mode="${2:-any}"
    [ -f "$f" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        if [ "$mode" = "no_llama" ]; then
            jq -e 'has("provider")' "$f" >/dev/null 2>&1 || return 1
        else
            jq -e '.provider["llama-local"]' "$f" >/dev/null 2>&1 || return 1
        fi
    else
        python3 - "$f" "$mode" <<'PY' >/dev/null 2>&1 || return 1
import json,sys
cfg=json.load(open(sys.argv[1]))
if sys.argv[2]!="no_llama":
    assert cfg["provider"]["llama-local"]
PY
    fi
    return 0
}

# json_field_eq: проверка конкретного поля (jq-выражение → ожидание)
json_field_eq() { # $1 file, $2 jq-expr, $3 expected
    local f="$1" expr="$2" expected="$3"
    local got
    if command -v jq >/dev/null 2>&1; then
        got="$(jq -r "$expr" "$f" 2>/dev/null)"
    else
        got="$(python3 -c "import json,sys; print(json.load(open('$f'))$2)" 2>/dev/null)"
    fi
    [ "$got" = "$expected" ]
}

# run_update: прогон opencode_update.sh над изолированным XDG_CONFIG_HOME
run_update() { # $1=test_dir, $2=model, $3=port
    XDG_CONFIG_HOME="$WORK/$1" bash "$UPDATE" "$2" "$3"
}

# cfg: путь к конфигу + jsonc-вариант
# (GLOBAL_DIR="$XDG_CONFIG_HOME/opencode" → файлы лежат на уровень глубже)
cfg() { echo "$WORK/$1/opencode/opencode.json"; }
cfg_jsonc() { echo "$WORK/$1/opencode/opencode.jsonc"; }

# --- case 'a': конфиг отсутствует → создаётся с нуля -------------------
echo "=== a: создание нового конфига ==="
run_update a qwen2.5-7b-instruct-q4_k_m.gguf 8081 >/dev/null 2>&1
assert_true "$(config_is_valid "$(cfg a)"; echo $?)" "a: создан валидный JSON"
assert_true "$(json_field_eq "$(cfg a)" '.provider["llama-local"].options.baseURL' 'http://127.0.0.1:8081/v1'; echo $?)" "a: baseURL=...8081/v1"
assert_true "$(json_field_eq "$(cfg a)" '.provider["llama-local"].models["qwen2.5-7b-instruct-q4_k_m.gguf"].name' 'qwen2.5-7b-instruct-q4_k_m.gguf'; echo $?)" "a: модель записана"

# ======================================================
echo "=== b: пустой {} → перезаписывается шаблоном ===="
mkdir -p "$WORK/b/opencode"
printf '{}\n' > "$(cfg b)"
run_update b model0.5.gguf 2 >/dev/null 2>&1
assert_true "$(config_is_valid "$(cfg b)"; echo $?)" "b: валидный JSON после пустого {}"
json_field_eq "$(cfg b)" '.provider["llama-local"].options.baseURL' 'http://127.0.0.1:2/v1'
assert_true "$?" "b: порт 2 подставлен в baseURL"

# ======================================================
echo "=== c: swap существующего llama-local (последний ключ, dangling comma) ==="
mkdir -p "$WORK/c/opencode"
cat > "$(cfg c)" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "other": {
      "k": 1
    },
    "llama-local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (local)",
      "options": {
        "baseURL": "http://127.0.0.1:8080/v1"
      },
      "models": {
        "old-model.gguf": {
          "name": "old-model.gguf"
        }
      }
    }
  }
}
EOF
# вызов: вторая модель/порт
run_update c new-model.gguf 9090 >/dev/null 2>&1
assert_true "$(config_is_valid "$(cfg c)"; echo $?)" "c: валидный JSON после swap"
assert_true "$(json_field_eq "$(cfg c)" ".provider.other.k" '1'; echo $?)" "c: сторонний ключ other сохранён"
assert_true "$(json_field_eq "$(cfg c)" '.provider["llama-local"].options.baseURL' 'http://127.0.0.1:9090/v1'; echo $?)" "c: baseURL обновлён на новый порт"
assert_true "$(json_field_eq "$(cfg c)" '.provider["llama-local"].models["new-model.gguf"].name' 'new-model.gguf'; echo $?)" "c: модель заменена"

# ======================================================
echo "=== d: swap при наличии других провайдеров + резервная копия ==="
mkdir -p "$WORK/d/opencode"
cat > "$(cfg d)" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama-local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (local)",
      "options": {
        "baseURL": "http://127.0.0.1:8080/v1"
      },
      "models": {}
    },
    "anthropic": {
      "npm": "@ai-sdk/anthropic"
    }
  },
  "theme": "dark"
}
EOF
run_update d model-x.gguf 7070 >/dev/null 2>&1
assert_true "$(config_is_valid "$(cfg d)"; echo $?)" "d: валидный JSON после swap"
assert_true "$(json_field_eq "$(cfg d)" '.theme' 'dark'; echo $?)" "d: theme сохранён"
assert_true "$(json_field_eq "$(cfg d)" '.provider.anthropic.npm' '@ai-sdk/anthropic'; echo $?)" "d: антропик сохранён"
assert_true "$(json_field_eq "$(cfg d)" '.provider["llama-local"].options.baseURL' 'http://127.0.0.1:7070/v1'; echo $?)" "d: новый порт"
assert_true "$( [ -f "$(cfg d).bak" ] && echo 0 )" "d: создан .bak"

# идемпотентность: повторный прогон не ломает конфиг
run_update d model-y.gguf 7171 >/dev/null 2>&1
assert_true "$(config_is_valid "$(cfg d)"; echo $?)" "d: повторный swap — валидный JSON"
assert_true "$(json_field_eq "$(cfg d)" '.provider["llama-local"].options.baseURL' 'http://127.0.0.1:7171/v1'; echo $?)" "d: порт обновился во второй раз"
assert_true "$( [ -f "$(cfg d).bak.bak" ] && echo 1 || echo 0 )" "d: второй .bak НЕ создан"

# ======================================================
echo "=== e: single-line конфиг не трогается ==="
mkdir -p "$WORK/e/opencode"
printf '{"$schema":"x","provider":{"p":{"a":1}}}' > "$(cfg e)"
bytes_before=$(wc -c < "$(cfg e)")
run_update e m.gguf 1234 >/dev/null 2>&1
bytes_after=$(wc -c < "$(cfg e)")
assert_eq "$bytes_before" "$bytes_after" "e: файл не изменён"

# ======================================================
echo "=== f: провайдер в одну строку не трогается ==="
mkdir -p "$WORK/f/opencode"
cat > "$(cfg f)" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": { "single": "json-file-marker-abc" }
}
EOF
run_update f m.gguf 1 >/dev/null 2>&1
assert_true "$(grep -q '"provider": { "single": "json-file-marker-abc" }' "$(cfg f)"; echo $?)" "f: провайдер в одну строку не тронут"

# ======================================================
echo "=== g: provider отсутствует → вставка перед корнем ==="
mkdir -p "$WORK/g/opencode"
cat > "$(cfg g)" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permissions": {
    "edit": true
  }
}
EOF
run_update g g-model.gguf 4242 >/dev/null 2>&1
assert_true "$(config_is_valid "$(cfg g)"; echo $?)" "g: валидный JSON после вставки провайдера"
assert_true "$(json_field_eq "$(cfg g)" '.permissions.edit' 'true'; echo $?)" "g: другой ключ сохранён"
assert_true "$(json_field_eq "$(cfg g)" '.provider["llama-local"].options.baseURL' 'http://127.0.0.1:4242/v1'; echo $?)" "g: llama-local на месте"

# ======================================================
echo "=== h: пустой (многострочный) provider — вставка внутрь ==="
mkdir -p "$WORK/h/opencode"
cat > "$(cfg h)" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
  }
}
EOF
run_update h set_k.gguf 311 >/dev/null 2>&1
assert_true "$(config_is_valid "$(cfg h)"; echo $?)" "h: валидный JSON"
assert_true "$(json_field_eq "$(cfg h)" '.provider["llama-local"].options.baseURL' 'http://127.0.0.1:311/v1'; echo $?)" "h: вставлено в пустой provider"

# ======================================================
echo "=== i: jsonc имеет приоритет над json ==="
mkdir -p "$WORK/i/opencode"
cat > "$WORK/i/opencode/opencode.jsonc" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "theme": "dark"
}
EOF
printf '{}\n' > "$WORK/i/opencode/opencode.json"
run_update i i.gguf 555 >/dev/null 2>&1
# обновляется должен быть .jsonc (выбирается global_target), json остаётся нетронутым
assert_true "$(config_is_valid "$WORK/i/opencode/opencode.jsonc"; echo $?)" "i: обновлён opencode.jsonc"
assert_eq '{}' "$(tr -d '[:space:]' < "$WORK/i/opencode/opencode.json")" "i: opencode.json не тронут"

# ======================================================
echo "=== j: модель не задана → код 1, сообщение в stderr ==="
OUT="$(XDG_CONFIG_HOME="$WORK/j" bash "$UPDATE" 2>&1 >/dev/null)"
assert_eq 1 "$?" "j: exit 1 при пустой модели"
assert_true "$(echo "$OUT" | grep -qi 'модель'; echo $?)" "j: сообщение об ошибке в stderr"

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "FAILURES: $FAILURES"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0