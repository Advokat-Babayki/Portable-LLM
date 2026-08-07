#!/bin/bash
# =====================================================
# opencode_update.sh — manages provider "llama-local" in
# opencode config with the currently loaded model id and
# its port. Zero external dependencies: bash, awk, sed.
#
#   PROJECT : <project>/opencode.json  (committed -> works
#             right after git clone, "из коробки")
#   GLOBAL  : $XDG_CONFIG_HOME/opencode or ~/.config/opencode
#
# Usage:
#   opencode_update.sh <model_id> <port>
#       Update the PROJECT config; if the GLOBAL config
#       already contains "llama.local", keep it in sync.
#       (Global config is never created/modified unless
#        the user has opted in by installing the block.)
#
#   opencode_update.sh --install-global <model> <port>
#       Opt-in: create/update "llama.local" in the GLOBAL
#       config so the local LLM works in every project.
# =====================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="$PROJECT_DIR/opencode.json"
GLOBAL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

MODE="update"
PARAMS=()

for arg in "$@"; do
    case "$arg" in
        --install-global) MODE="install-global" ;;
        *) PARAMS+=("$arg") ;;
    esac
done

MODEL="${PARAMS[0]:-}"
PORT="${PARAMS[1]:-8080}"
[ -z "$MODEL" ] && { echo "[opencode] ошибка: укажите модель (имя .gguf файла)" >&2; exit 1; }

# ------------------------------------------------------------------
# generate the "llama-local" provider object (4-space indent,
# no trailing comma). Prints to stdout. Used as a block swap-in.
# ------------------------------------------------------------------
generate_block() {
    cat <<EOF
    "llama-local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp (local)",
      "options": {
        "baseURL": "http://127.0.0.1:${PORT}/v1"
      },
      "models": {
        "${MODEL}": {
          "name": "${MODEL}"
        }
      }
    }
EOF
}

# ------------------------------------------------------------------
# Write a fresh minimal config (file does not exist).
# ------------------------------------------------------------------
write_fresh() {
    local target="$1"
    {
        echo "{"
        echo "  \"\$schema\": \"https://opencode.ai/config.json\","
        echo "  \"provider\": {"
        generate_block
        echo "  }"
        echo "}"
    } > "$target"
    echo "[+] создан $target (model=$MODEL, port=$PORT)"
}

# ------------------------------------------------------------------
# Replace an existing "llama-local" block inside any valid nesting,
# keeping the rest of the file byte-identical. Fixes a dangling
# comma when the block was the last key inside "provider".
# ------------------------------------------------------------------
swap_llama() {
    local file="$1"
    local tmp="$1.swap"
    local blk="$1.block"

    generate_block > "$blk"

    awk -v blk="$blk" '
    function bcount(l){ t=l; return (gsub(/{/,"{",t) - gsub(/}/,"}",t)) }
    {
        if (!ind && $0 ~ /"llama-local"[[:space:]]*:[[:space:]]*\{/) {
            dep=bcount($0); found=1; emit()
            if (dep <= 0) ind = 0   # whole object was on this single line
            else          ind = 1
            next
        }
        if (ind) {
            dep += bcount($0)
            if (dep <= 0) ind = 0
            next
        }
        print
    }
    function emit() { while ((getline line < blk) > 0) print line }
    ' "$file" > "$tmp"
    local rc=$?
    rm -f "$blk"
    if [ $rc -ne 0 ]; then rm -f "$tmp"; return 1; fi

    awk '
    {
        if (prev != "") {
            if ($0 ~ /^[[:space:]]*}/ && prev ~ /,$/) sub(/, $/, "", prev)
            print prev
        }
        prev = $0
    }
    END { print prev }
    ' "$tmp" > "$file"
    rm -f "$tmp"
    echo "[+] обновлён $file (model=$MODEL, port=$PORT)"
    return 0
}

# ------------------------------------------------------------------
# Insert "llama-local" into a config that has no llama block yet:
#   - provider present (empty or not) -> insert inside it
#   - provider missing                -> append a new section
# ------------------------------------------------------------------
insert_llama() {
    local file="$1"
    local tmp="$file.ins"
    local blk="$file.block"

    # empty JSON object -> just (re)write the managed template
    if [ "$(tr -d '[:space:]' < "$file")" = "{}" ]; then
        write_fresh "$file"
        return 0
    fi

    # SAFETY: refuse single-line configs / inline provider objects.
    # Merging into those would require a JSON parser; better to leave
    # the file untouched than to risk corrupting the user's config.
    local nlines
    nlines=$(awk 'END{print NR}' "$file")
    if [ "${nlines:-0}" -le 1 ]; then
        echo "[opencode][!] $file записан в одну строку — не буду менять его автоматически."
        echo "[opencode]     Чтобы включить авто-обновление, удалите его (будет создан заново)"
        echo "[opencode]     или перезапишите в многострочном виде."
        return 0
    fi

    if grep -q '"provider"' "$file" && \
       awk 'BEGIN{f=0} /"provider"[[:space:]]*:[[:space:]]*\{[[:space:]]*\{?[^}]*}/ {f=1} END{exit (f?0:1)}' "$file"; then
        echo "[opencode][!] конфиг с провайдером в одну строку — авто-вставка отменена (файл не тронут)."
        return 0
    fi

    generate_block > "$blk"

    if ! grep -q '"provider"' "$file"; then
        # ---- no "provider": append a new section before root close ----
        awk -v blk="$blk" '
        function bcount(l){ t=l; return (gsub(/{/,"{",t) - gsub(/}/,"}",t)) }
        { lines[n++]=$0; dep+=bcount($0); if (dep==0) rootclose=n-1 }
        END {
            if (rootclose < 0) { print "JSON: object braces not found" > "/dev/stderr"; exit 1 }
            empty=1
            for (i=1;i<rootclose;i++) if (lines[i] !~ /^[[:space:]]*$/) empty=0
            for (i=0;i<n;i++) {
                if (i==rootclose) {
                    if (empty) printf "  \"provider\": {\n"
                    else       printf ",\n  \"provider\": {\n"
                    while ((getline line < blk) > 0) print line
                    close(blk)
                    print "  }"
                    print lines[i]
                } else print lines[i]
            }
        }
        ' "$file" > "$tmp"
        local rcp=$?
    else
        # ---- provider present, multi-line: insert block before its keys ----
        awk -v blk="$blk" '
        function bcount(t){ return (gsub(/{/,"{",t) - gsub(/}/,"}",t)) }
        function load(){ for(i=0;(getline line < blk)>0;i++) blkarr[i]=line; blklen=i; close(blk) }
        function emit_block(trail){
            for (i=0;i<blklen;i++)
                if (i==blklen-1 && trail) printf "%s,\n", blkarr[i]
                else print blkarr[i]
        }
        BEGIN { blklen=0; done=0; load() }
        {
            if (ind) {
                dep += bcount($0)
                if (dep > 0) { buf[bcnt++]=$0; next }
                empty = 1
                for (i=0;i<bcnt;i++) if (buf[i] !~ /^[[:space:]]*$/) empty=0
                if (empty) emit_block(0)
                else       { emit_block(1); for (i=0;i<bcnt;i++) print buf[i] }
                print $0
                ind = 0
                next
            }
            if (!done && $0 ~ /"provider"[[:space:]]*:[[:space:]]*\{/) {
                print $0
                ind = 1
                dep = bcount($0)
                done = 1
                next
            }
            print
        }
        ' "$file" > "$tmp"
        local rcp=$?
    fi

    rm -f "$blk"
    if [ "${rcp:-1}" -ne 0 ]; then rm -f "$tmp"; return 1; fi
    [ -f "$tmp" ] && mv "$tmp" "$file"
    echo "[+] в $file добавлен провайдер llama-local"
    return 0
}

# ------------------------------------------------------------------
# Update one config file. DO_INSERT=1 forces insertion when missing.
# ------------------------------------------------------------------
update_file() {
    local target="$1"
    if [ ! -f "$target" ]; then
        write_fresh "$target"
        return 0
    fi
    if grep -q '"llama-local"' "$target"; then
        swap_llama "$target"
        return $?
    fi
    if [ "${DO_INSERT:-0}" = "1" ]; then
        insert_llama "$target"
        return $?
    fi
    return 0
}

# ------------------------------------------------------------------
# One-time backup of a global config before first modification.
# ------------------------------------------------------------------
backup_if_global() {
    local target="$1"
    case "$target" in
        "$GLOBAL_DIR"/*)
            if [ -f "$target" ] && [ ! -f "$target.bak" ]; then
                cp -p "$target" "$target.bak" 2>/dev/null
                echo "[i] резервная копия: $target.bak"
            fi
            ;;
    esac
}

global_target() {
    for f in "$GLOBAL_DIR/opencode.jsonc" "$GLOBAL_DIR/opencode.json"; do
        [ -f "$f" ] && { echo "$f"; return 0; }
    done
    echo "$GLOBAL_DIR/opencode.json"
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
if [ "$MODE" = "install-global" ]; then
    mkdir -p "$GLOBAL_DIR" 2>/dev/null
    G=$(global_target)
    backup_if_global "$G"
    DO_INSERT=1 update_file "$G"
    echo "[i] локальный LLM доступен во всех папках (global: $G)"
    exit 0
fi

# default: update the project config
DO_INSERT=1 update_file "$CONFIG"

# sync global only if llama-local is already installed there (opt-in)
G=$(global_target)
if [ -f "$G" ] && grep -q '"llama-local"' "$G"; then
    backup_if_global "$G"
    swap_llama "$G"
fi
exit 0