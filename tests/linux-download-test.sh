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

source "$ROOT/tests/lib/bash-assert.sh"
source "$ROOT/tests/lib/bash-sandbox.sh"

# -------------------------------------------------------------
# Версии из единого источника
# -------------------------------------------------------------
# Версии из единого источника
# -------------------------------------------------------------
source "$ROOT/lib/versions.inc"

# =============================================================
echo "=== 1. Все бинарники на месте → скачивание не запускается ==="
SB1="$(mktemp -d "$WORK/s1.XXXX")"
make_hw_stubs "$SB1" cpu; make_dl_stubs "$SB1"; install_launcher "$SB1"
# Создаём все три ключевых файла — короткое замыкание
printf 'x\n' > "$SB1/bin/linux-cpu/llama-server"
printf 'x\n' > "$SB1/bin/linux-vulkan/llama-server"
printf 'x\n' > "$SB1/whisper/bin/linux-cpu/whisper-server"
DL_RECORD="$WORK/dl1.rec" run_cli "$SB1" --silent --model no-such-model.gguf >/dev/null 2>&1
assert_true "$([ ! -f "$WORK/dl1.rec" ]; echo $?)" "1: curl не вызывался (рекорд пуст)"

# =============================================================
echo "=== 2. Успешное скачивание: все архивы, URL из versions.inc ==="
SB2="$(mktemp -d "$WORK/s2.XXXX")"
make_hw_stubs "$SB2" cpu; make_dl_stubs "$SB2"; install_launcher "$SB2"
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
make_hw_stubs "$SB3" cpu; install_launcher "$SB3"
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
make_hw_stubs "$SB4" cpu; make_dl_stubs "$SB4"; install_launcher "$SB4"
out="$(STUB_CURL_FAIL=1 DL_RECORD="$WORK/dl4.rec" run_cli "$SB4" --silent --model x.gguf 2>&1)"
rc=$?
assert_eq 1 "$rc" "4: exit 1 при сбое скачивания"
assert_true "$(echo "$out" | grep -q 'Не удалось скачать'; echo $?)" "4: сообщение 'Не удалось скачать'"

# =============================================================
echo "=== 5. Ошибка распаковки (tar) → ошибка ==="
SB5="$(mktemp -d "$WORK/s5.XXXX")"
make_hw_stubs "$SB5" cpu; make_dl_stubs "$SB5"; install_launcher "$SB5"
out="$(STUB_TAR_FAIL=1 DL_RECORD="$WORK/dl5.rec" run_cli "$SB5" --silent --model x.gguf 2>&1)"
rc=$?
assert_eq 1 "$rc" "5: exit 1 при ошибке распаковки"
assert_true "$(echo "$out" | grep -q 'Ошибка распаковки'; echo $?)" "5: сообщение 'Ошибка распаковки'"

# =============================================================
echo "=== 6. Слишком маленький архив (< 1 МБ) → ошибка ==="
SB6="$(mktemp -d "$WORK/s6.XXXX")"
make_hw_stubs "$SB6" cpu; make_dl_stubs "$SB6"; install_launcher "$SB6"
out="$(STUB_STAT_SIZE=500 DL_RECORD="$WORK/dl6.rec" run_cli "$SB6" --silent --model x.gguf 2>&1)"
rc=$?
assert_eq 1 "$rc" "6: exit 1 при подозрительно малом файле"
assert_true "$(echo "$out" | grep -q 'подозрительно мал'; echo $?)" "6: сообщение о малом размере"

# =============================================================
echo "=== 7. Ключевой файл не появился после распаковки → ошибка ==="
SB7="$(mktemp -d "$WORK/s7.XXXX")"
make_hw_stubs "$SB7" cpu; make_dl_stubs "$SB7"; install_launcher "$SB7"
out="$(STUB_TAR_NOKEY=1 DL_RECORD="$WORK/dl7.rec" run_cli "$SB7" --silent --model x.gguf 2>&1)"
rc=$?
assert_eq 1 "$rc" "7: exit 1 при отсутствии ключевого файла"
assert_true "$(echo "$out" | grep -q 'не найден файл'; echo $?)" "7: сообщение о ключевом файле"

test_done
