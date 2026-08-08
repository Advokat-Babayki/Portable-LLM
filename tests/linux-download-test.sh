#!/bin/bash
# =====================================================
# linux-download-test.sh — тест ветки скачивания бинарников
# Проверяет download_binaries()/ensure_binaries() из Lunix.sh:
#   * короткое замыкание, когда все бинарники на месте;
#   * успешное скачивание трёх архивов (CPU/Vulkan/Whisper);
#   * URL из lib/versions.inc — единый источник версий;
#   * ветки ошибок: нет curl/wget, сбой скачивания, распаковки,
#     слишком маленький архив, отсутствие ключевого файла.
# Детерминированно: PATH-стабы curl/tar/stat, никакой сети.
# Запуск: bash tests/linux-download-test.sh  (exit 0 при успехе)
# =====================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0

assert_eq() {
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

# -------------------------------------------------------------
# Стабы "железа" (как в linux-cli-test.sh)
# -------------------------------------------------------------
make_hw_stubs() { # $1=sandbox
    local sb="$1"
    local p; p="$(stubdir "$sb")"
    mkdir -p "$p" "$sb/lib" "$sb/models" "$sb/whisper/models" \
             "$sb/bin/linux-cpu" "$sb/bin/linux-vulkan" "$sb/whisper/bin/linux-cpu"

    cat > "$p/free" <<'EOF'
#!/bin/sh
if [ "$1" = "-m" ]; then echo '              total        used        free      shared     buff/cache   available'; fi
echo 'Mem:       131072       2000    129072       100      2000    4000'
echo 'Swap:      16000           0     16000'
EOF
    chmod +x "$p/free"

    cat > "$p/lscpu" <<'EOF'
#!/bin/sh
echo 'CPU(s):             8'
echo 'Thread(s) per core: 2'
echo 'Core(s) per socket: 4'
echo 'Socket(s):          1'
echo 'Vendor ID:          GenuineIntel'
echo 'Flags:              avx2'
EOF
    chmod +x "$p/lscpu"

    printf '#!/bin/sh\nexit 0\n' > "$p/ss";     chmod +x "$p/ss"
    printf '#!/bin/sh\nexit 0\n' > "$p/xdg-open"; chmod +x "$p/xdg-open"
}

# -------------------------------------------------------------
# Стабы скачивания: curl/tar/stat
#   curl   — пишет "архив" и логирует аргументы в $DL_RECORD
#   tar    — "распаковывает" создавая ключевые файлы
#   stat   — всегда больший размер (если не STUB_STAT_SIZE)
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

install_launcher() {
    cp "$ROOT/Lunix.sh" "$1/Lunix.sh"
    chmod +x "$1/Lunix.sh"
    rm -rf "$1/lib"
    cp -r "$ROOT/lib" "$1/"
}

run_cli() { # $1=sandbox, ...args
    local sb="$1"; shift
    env PATH="$(stubdir "$sb"):$PATH" XDG_CONFIG_HOME="$sb/xdg" \
        "$sb/Lunix.sh" "$@"
}

# -------------------------------------------------------------
# Версии из единого источника
# -------------------------------------------------------------
source "$ROOT/lib/versions.inc"

# =============================================================
echo "=== 1. Все бинарники на месте → скачивание не запускается ==="
SB1="$(mktemp -d "$WORK/s1.XXXX")"
make_hw_stubs "$SB1"; make_dl_stubs "$SB1"; install_launcher "$SB1"
# Создаём все три ключевых файла — короткое замыкание
printf 'x\n' > "$SB1/bin/linux-cpu/llama-server"
printf 'x\n' > "$SB1/bin/linux-vulkan/llama-server"
printf 'x\n' > "$SB1/whisper/bin/linux-cpu/whisper-server"
DL_RECORD="$WORK/dl1.rec" run_cli "$SB1" --silent --model no-such-model.gguf >/dev/null 2>&1
assert_true "$([ ! -f "$WORK/dl1.rec" ]; echo $?)" "1: curl не вызывался (рекорд пуст)"

# =============================================================
echo "=== 2. Успешное скачивание: все архивы, URL из versions.inc ==="
SB2="$(mktemp -d "$WORK/s2.XXXX")"
make_hw_stubs "$SB2"; make_dl_stubs "$SB2"; install_launcher "$SB2"
# Модель не создаём — после скачивания скрипт уйдёт на "Модель не найдена",
# но это и есть точка остановки после успешного ensure_binaries.
DL_RECORD="$WORK/dl2.rec" run_cli "$SB2" --silent --model no-model.gguf >/dev/null 2>&1
assert_true "$([ -f "$WORK/dl2.rec" ]; echo $?)" "2: curl вызывался (рекорд создан)"
assert_eq "$(wc -l < "$WORK/dl2.rec")" 3 "2: скачано 3 архива (CPU/Vulkan/Whisper)"
assert_true "$([ -x "$SB2/bin/linux-cpu/llama-server" ]; echo $?)" "2: bin/linux-cpu/llama-server готов"
assert_true "$([ -x "$SB2/bin/linux-vulkan/llama-server" ]; echo $?)" "2: bin/linux-vulkan/llama-server готов"
assert_true "$([ -x "$SB2/whisper/bin/linux-cpu/whisper-server" ]; echo $?)" "2: whisper/bin/linux-cpu/whisper-server готов"
grep -q "llama-${LLAMA_VERSION}-bin-ubuntu-x64.tar.gz" "$WORK/dl2.rec"
assert_true "$?" "2: CPU-URL содержит версию llama ${LLAMA_VERSION}"
grep -q "llama-${LLAMA_VERSION}-bin-ubuntu-vulkan-x64.tar.gz" "$WORK/dl2.rec"
assert_true "$?" "2: Vulkan-URL содержит версию llama ${LLAMA_VERSION}"
grep -q "whisper-bin-ubuntu-x64.tar.gz" "$WORK/dl2.rec"
assert_true "$?" "2: Whisper-URL содержит версию whisper ${WHISPER_VERSION}"

# =============================================================
echo "=== 3. Нет curl и wget → инструкция и exit 1 (headless) ==="
SB3="$(mktemp -d "$WORK/s3.XXXX")"
make_hw_stubs "$SB3"; install_launcher "$SB3"
# Убираем стабы curl/wget из PATH и прячем системные — минимальный PATH
mini="$SB3/minpath"
mkdir -p "$mini"
for t in grep awk sed tr cut sort wc mkdir mktemp basename rm tar find chmod sleep date tee cat head dirname; do
    if command -v "$t" >/dev/null 2>&1; then
        ln -s "$(command -v "$t")" "$mini/$t"
    fi
done
# cp не в списке, добавим отдельно (используется в make_hw_stubs до этого)
ln -s "$(command -v cp)" "$mini/cp" 2>/dev/null || true
out="$(env PATH="$mini" XDG_CONFIG_HOME="$SB3/xdg" "$SB3/Lunix.sh" --silent --model x.gguf 2>&1)"
rc=$?
assert_eq 1 "$rc" "3: exit 1 при отсутствии curl/wget"
assert_true "$(echo "$out" | grep -q 'ни curl, ни wget'; echo $?)" "3: сообщение про curl/wget"

# =============================================================
echo "=== 4. Сбой скачивания (curl) → ошибка и exit 1 ==="
SB4="$(mktemp -d "$WORK/s4.XXXX")"
make_hw_stubs "$SB4"; make_dl_stubs "$SB4"; install_launcher "$SB4"
out="$(STUB_CURL_FAIL=1 DL_RECORD="$WORK/dl4.rec" run_cli "$SB4" --silent --model x.gguf 2>&1)"
rc=$?
assert_eq 1 "$rc" "4: exit 1 при сбое скачивания"
assert_true "$(echo "$out" | grep -q 'Не удалось скачать'; echo $?)" "4: сообщение 'Не удалось скачать'"

# =============================================================
echo "=== 5. Ошибка распаковки (tar) → ошибка ==="
SB5="$(mktemp -d "$WORK/s5.XXXX")"
make_hw_stubs "$SB5"; make_dl_stubs "$SB5"; install_launcher "$SB5"
out="$(STUB_TAR_FAIL=1 DL_RECORD="$WORK/dl5.rec" run_cli "$SB5" --silent --model x.gguf 2>&1)"
rc=$?
assert_eq 1 "$rc" "5: exit 1 при ошибке распаковки"
assert_true "$(echo "$out" | grep -q 'Ошибка распаковки'; echo $?)" "5: сообщение 'Ошибка распаковки'"

# =============================================================
echo "=== 6. Слишком маленький архив (< 1 МБ) → ошибка ==="
SB6="$(mktemp -d "$WORK/s6.XXXX")"
make_hw_stubs "$SB6"; make_dl_stubs "$SB6"; install_launcher "$SB6"
out="$(STUB_STAT_SIZE=500 DL_RECORD="$WORK/dl6.rec" run_cli "$SB6" --silent --model x.gguf 2>&1)"
rc=$?
assert_eq 1 "$rc" "6: exit 1 при подозрительно малом файле"
assert_true "$(echo "$out" | grep -q 'подозрительно мал'; echo $?)" "6: сообщение о малом размере"

# =============================================================
echo "=== 7. Ключевой файл не появился после распаковки → ошибка ==="
SB7="$(mktemp -d "$WORK/s7.XXXX")"
make_hw_stubs "$SB7"; make_dl_stubs "$SB7"; install_launcher "$SB7"
out="$(STUB_TAR_NOKEY=1 DL_RECORD="$WORK/dl7.rec" run_cli "$SB7" --silent --model x.gguf 2>&1)"
rc=$?
assert_eq 1 "$rc" "7: exit 1 при отсутствии ключевого файла"
assert_true "$(echo "$out" | grep -q 'не найден файл'; echo $?)" "7: сообщение о ключевом файле"

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "FAILURES: $FAILURES"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
