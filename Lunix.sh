#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
#  МОДУЛИ lib/ (детект железа + общие функции)
#  Если lib/ отсутствует — скрипт работает в прежнем режиме
#  с фиксированными параметрами (-c 8192, -ngl 99, порты 8080/8081).
# ============================================================
LIB_OK=false
if [ -f "$SCRIPT_DIR/lib/detect_hw.sh" ] && [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    source "$SCRIPT_DIR/lib/detect_hw.sh" 2>/dev/null
    source "$SCRIPT_DIR/lib/common.sh" 2>/dev/null
    if [ -n "${HW_RAM_TOTAL_MB:-}" ]; then
        LIB_OK=true
    fi
fi

# ============================================================
#  НАСТРОЙКИ БИНАРНИКОВ
#  Бинарники НЕ лежат в репозитории — при первом запуске скрипт
#  скачивает официальные сборки llama.cpp и whisper.cpp.
#  Вышла новая версия — поменяй версию ниже и перезапусти скрипт.
# ============================================================
LLAMA_VERSION="b9932"      # https://github.com/ggml-org/llama.cpp/releases
WHISPER_VERSION="v1.9.2"   # https://github.com/ggml-org/whisper.cpp/releases

LLAMA_URL_BASE="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_VERSION}"
WHISPER_URL_BASE="https://github.com/ggml-org/whisper.cpp/releases/download/${WHISPER_VERSION}"

BIN_URL_LLAMA_CPU_LINUX="${LLAMA_URL_BASE}/llama-${LLAMA_VERSION}-bin-ubuntu-x64.tar.gz"
BIN_URL_LLAMA_VK_LINUX="${LLAMA_URL_BASE}/llama-${LLAMA_VERSION}-bin-ubuntu-vulkan-x64.tar.gz"
BIN_URL_WHISPER_CPU_LINUX="${WHISPER_URL_BASE}/whisper-bin-ubuntu-x64.tar.gz"

# ============================================================
#  ФУНКЦИИ ЗАГРУЗКИ БИНАРНИКОВ
# ============================================================

download_binaries() {
    # Аргументы: $1 = URL, $2 = папка назначения, $3 = ключевой файл для проверки
    local url="$1"
    local dest_dir="$2"
    local key_file="$3"
    local archive=""
    local tmp_dir=""
    local size=0

    echo "  → $url"

    mkdir -p "$dest_dir" || return 1
    tmp_dir="$(mktemp -d)" || { echo "[!] Не удалось создать временную папку"; return 1; }
    archive="$tmp_dir/$(basename "$url")"

    if command -v curl >/dev/null 2>&1; then
        curl -fSL --retry 5 --connect-timeout 15 -o "$archive" "$url" || {
            echo "[!] Ошибка скачивания: $url"; rm -rf "$tmp_dir"; return 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$archive" --tries=5 --timeout=15 "$url" || {
            echo "[!] Ошибка скачивания: $url"; rm -rf "$tmp_dir"; return 1; }
    else
        echo "[!] Не найден ни curl, ни wget. Установите один из них, например:"
        echo "    sudo apt install curl   (Debian/Ubuntu)"
        echo "    sudo pacman -S curl     (Arch)"
        echo "    sudo dnf install curl   (Fedora)"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Проверка размера: меньше 1 МБ — почти наверняка страница ошибки вместо архива
    size="$(stat -c %s "$archive" 2>/dev/null || echo 0)"
    if [ "$size" -lt 1000000 ]; then
        echo "[!] Скачанный файл подозрительно мал (${size} байт). Проверьте ссылку."
        rm -rf "$tmp_dir"
        return 1
    fi

    # Официальные архивы содержат вложенную папку (llama-b9932/ и т.п.) — срезаем её
    if ! tar -xzf "$archive" --strip-components=1 -C "$dest_dir" 2>/dev/null; then
        echo "[!] Ошибка распаковки архива: $archive"
        rm -rf "$tmp_dir"
        return 1
    fi

    chmod -R u+rwX,go+rX "$dest_dir" 2>/dev/null
    find "$dest_dir" -maxdepth 1 -type f -exec chmod +x {} \; 2>/dev/null

    rm -rf "$tmp_dir"

    if [ ! -f "$dest_dir/$key_file" ]; then
        echo "[!] После распаковки не найден файл $key_file — архив повреждён или не подходит"
        return 1
    fi

    echo "  ✓ OK"
    return 0
}

ensure_binaries() {
    # Если все ключевые бинарники на месте — ничего не делаем
    [ -f "$SCRIPT_DIR/bin/linux-cpu/llama-server" ] \
        && [ -f "$SCRIPT_DIR/bin/linux-vulkan/llama-server" ] \
        && [ -f "$SCRIPT_DIR/whisper/bin/linux-cpu/whisper-server" ] \
        && return 0

    echo ""
    echo "==================================================="
    echo "   Скачивание необходимых бинарников..."
    echo "   llama.cpp ${LLAMA_VERSION} + whisper.cpp ${WHISPER_VERSION}"
    echo "   (официальные сборки ggml-org — скачиваются один раз)"
    echo "==================================================="
    echo ""

    if ! command -v tar >/dev/null 2>&1; then
        echo "[!] Не найден tar. Установите его: sudo apt install tar"
        return 1
    fi

    local failed=0

    if [ ! -f "$SCRIPT_DIR/bin/linux-cpu/llama-server" ]; then
        echo "[LLM CPU]"
        download_binaries "$BIN_URL_LLAMA_CPU_LINUX" "$SCRIPT_DIR/bin/linux-cpu" "llama-server" || failed=1
    fi
    if [ ! -f "$SCRIPT_DIR/bin/linux-vulkan/llama-server" ]; then
        echo "[LLM Vulkan]"
        download_binaries "$BIN_URL_LLAMA_VK_LINUX" "$SCRIPT_DIR/bin/linux-vulkan" "llama-server" || failed=1
    fi
    if [ ! -f "$SCRIPT_DIR/whisper/bin/linux-cpu/whisper-server" ]; then
        echo "[Whisper CPU]"
        download_binaries "$BIN_URL_WHISPER_CPU_LINUX" "$SCRIPT_DIR/whisper/bin/linux-cpu" "whisper-server" || failed=1
    fi

    if [ "$failed" -ne 0 ]; then
        echo ""
        echo "[!] Не удалось скачать все бинарники. Проверьте интернет и версии"
        echo "    в начале скрипта (LLAMA_VERSION / WHISPER_VERSION)."
        echo "    Вручную архивы берутся здесь:"
        echo "      llama.cpp:   https://github.com/ggml-org/llama.cpp/releases"
        echo "      whisper.cpp: https://github.com/ggml-org/whisper.cpp/releases"
        echo "    Распаковать их нужно в bin/ и whisper/bin/."
        read -p "Нажмите Enter для выхода..."
        exit 1
    fi

    echo ""
    echo "Бинарники готовы. Запускаю лаунчер..."
    sleep 1
}

ensure_binaries || exit 1

while true; do
    clear
    echo "==================================================="
    echo "          LLM & Whisper Launcher — Linux"
    echo "==================================================="
    if [ "$LIB_OK" = true ]; then
        print_hw_info
        echo ""
    fi
    echo ""
    echo "  1) 💬 Текстовая нейросеть (LLM / Чат)"
    echo "  2) 🎙️  Распознавание речи (Whisper)"
    echo "  q) Выход"
    echo ""
    echo "==================================================="
    read -p "Выберите категорию (1-2): " cat_choice

    case $cat_choice in
        1)
            # --- РЕЖИМ LLM ---
            MODELS_DIR="$SCRIPT_DIR/models"
            while true; do
                clear
                echo "==================================================="
                echo "             Выбор текстовой модели (LLM)"
                echo "==================================================="
                echo ""

                mapfile -t MODELS < <(find "$MODELS_DIR" -maxdepth 1 -type f -name "*.gguf" -printf "%f\n" 2>/dev/null)

                if [ ${#MODELS[@]} -eq 0 ]; then
                    echo "[!] Внимание: Папка models/ пуста или не содержит файлов .gguf!"
                    echo "Закинь файл модели в: $MODELS_DIR"
                    echo ""
                    read -p "Нажми Enter для возврата..."
                    break
                fi

                echo "Доступные модели:"
                for i in "${!MODELS[@]}"; do
                    if [ "$LIB_OK" = true ]; then
                        local_size=$(get_model_size_mb "${MODELS[$i]}" "$MODELS_DIR")
                        echo "  $((i+1))) ${MODELS[$i]} (~$local_size MB)"
                    else
                        echo "  $((i+1))) ${MODELS[$i]}"
                    fi
                done
                echo "  b) Назад в главное меню"
                echo ""
                echo "==================================================="
                read -p "Выберите номер модели (1-${#MODELS[@]}): " m_choice

                if [[ "$m_choice" == "b" || "$m_choice" == "B" ]]; then
                    break
                fi

                if ! [[ "$m_choice" =~ ^[0-9]+$ ]] || [ "$m_choice" -lt 1 ] || [ "$m_choice" -gt "${#MODELS[@]}" ]; then
                    echo "Неверный выбор!"
                    sleep 1
                    continue
                fi

                SELECTED_MODEL="${MODELS[$((m_choice-1))]}"

                while true; do
                    clear
                    echo "==================================================="
                    echo "Выбрана модель: $SELECTED_MODEL"
                    echo "==================================================="
                    echo ""
                    echo "Режим работы:"
                    echo "  1) CPU    (Чистая обработка, запустится ВЕЗДЕ)"
                    echo "  2) Vulkan (GPU ускорение AMD / Intel / Nvidia)"
                    echo "  b) Назад к выбору модели"
                    echo ""
                    echo "==================================================="
                    read -p "Выберите режим (1-2): " r_choice

                    case $r_choice in
                        1)
                            echo -e "\n[Запуск LLM $SELECTED_MODEL на CPU...]"
                            echo "Адрес веб-интерфейса: http://127.0.0.1:8080"
                            cd "$SCRIPT_DIR/bin/linux-cpu"
                            chmod +x llama-server 2>/dev/null
                            ./llama-server -m "../../models/$SELECTED_MODEL" -c 8192 --host 127.0.0.1 --port 8080
                            read -p "Сервер остановлен. Нажмите Enter..."
                            break
                            ;;
                        2)
                            echo -e "\n[Запуск LLM $SELECTED_MODEL на Vulkan GPU...]"
                            echo "Адрес веб-интерфейса: http://127.0.0.1:8080"
                            cd "$SCRIPT_DIR/bin/linux-vulkan"
                            chmod +x llama-server 2>/dev/null
                            ./llama-server -m "../../models/$SELECTED_MODEL" -ngl 99 -c 8192 --host 127.0.0.1 --port 8080
                            read -p "Сервер остановлен. Нажмите Enter..."
                            break
                            ;;
                        b|B)
                            break
                            ;;
                        *)
                            echo "Неверный выбор."
                            sleep 1
                            ;;
                    esac
                done
            done
            ;;

        2)
            # --- РЕЖИМ WHISPER ---
            WHISPER_MODELS_DIR="$SCRIPT_DIR/whisper/models"
            while true; do
                clear
                echo "==================================================="
                echo "          Выбор модели Whisper (Аудио в текст)"
                echo "==================================================="
                echo ""

                mapfile -t W_MODELS < <(find "$WHISPER_MODELS_DIR" -maxdepth 1 -type f \( -name "*.bin" -o -name "*.gguf" \) -printf "%f\n" 2>/dev/null)

                if [ ${#W_MODELS[@]} -eq 0 ]; then
                    echo "[!] Внимание: Папка whisper/models/ пуста!"
                    echo "Закинь файл модели (.bin или .gguf) в: $WHISPER_MODELS_DIR"
                    echo ""
                    read -p "Нажми Enter для возврата..."
                    break
                fi

                echo "Доступные модели Whisper:"
                for i in "${!W_MODELS[@]}"; do
                    if [ "$LIB_OK" = true ]; then
                        local_size=$(get_model_size_mb "${W_MODELS[$i]}" "$WHISPER_MODELS_DIR")
                        echo "  $((i+1))) ${W_MODELS[$i]} (~$local_size MB)"
                    else
                        echo "  $((i+1))) ${W_MODELS[$i]}"
                    fi
                done
                echo "  b) Назад в главное меню"
                echo ""
                echo "==================================================="
                read -p "Выберите номер модели (1-${#W_MODELS[@]}): " w_choice

                if [[ "$w_choice" == "b" || "$w_choice" == "B" ]]; then
                    break
                fi

                if ! [[ "$w_choice" =~ ^[0-9]+$ ]] || [ "$w_choice" -lt 1 ] || [ "$w_choice" -gt "${#W_MODELS[@]}" ]; then
                    echo "Неверный выбор!"
                    sleep 1
                    continue
                fi

                SELECTED_W_MODEL="${W_MODELS[$((w_choice-1))]}"

                while true; do
                    clear
                    echo "==================================================="
                    echo "Выбрана модель Whisper: $SELECTED_W_MODEL"
                    echo "==================================================="
                    echo ""
                    echo "Режим работы:"
                    echo "  1) CPU    (Обработка на процессоре)"
                    echo "  (Vulkan для Whisper в официальных сборках не поставляется)"
                    echo "  b) Назад к выбору модели"
                    echo ""
                    echo "==================================================="
                    read -p "Выберите режим (1): " wr_choice

                    case $wr_choice in
                        1)
                            echo -e "\n[Запуск Whisper $SELECTED_W_MODEL на CPU...]"
                            echo "Адрес веб-интерфейса: http://127.0.0.1:8081"
                            cd "$SCRIPT_DIR/whisper/bin/linux-cpu"
                            chmod +x whisper-server 2>/dev/null
                            ./whisper-server -m "../../models/$SELECTED_W_MODEL" --host 127.0.0.1 --port 8081
                            read -p "Сервер остановлен. Нажмите Enter..."
                            break
                            ;;
                        b|B)
                            break
                            ;;
                        *)
                            echo "Неверный выбор."
                            sleep 1
                            ;;
                    esac
                done
            done
            ;;

        q|Q)
            exit 0
            ;;
        *)
            echo "Неверный выбор."
            sleep 1
            ;;
    esac
done
