# AGENTS.md — контекст для ИИ-сессий и разработчиков

Этот файл автоматически подхватывает opencode при старте сессии. Здесь —
что где лежит, как всё тестируется и какие грабли уже разгрёбаны. Пользователь
README не читает этот контекст; весь девелоперский бэкграунд живёт здесь.

## Что это

Портативный лаунчер для llama.cpp (LLM) и whisper.cpp (распознавание речи):
- **Linux** — `Lunix.sh` (bash); **Windows** — `Windows.bat` (чистый
  cmd-скрипт, без PowerShell-обёртки).
- Бинарники и модели **не хранятся в Git**. При первом запуске скачиваются
  сборки llama.cpp/whisper.cpp из официальных `ggml-org` релизов в `bin/` и
  `whisper/bin/`. Пользователь кладёт `.gguf` (LLM) / `.bin` (Whisper) сам.
- Версии бинарников задаются в **`lib/versions.inc`** (единый источник:
  `Lunix.sh` — `source`, `Windows.bat` — `findstr` с фолбэком, CI читает
  оттуда же). Не хардкодь версии в трёх местах.
- Общая Windows-логика вынесена в `lib/*.ps1`: `common.ps1` (порты, краш-логи,
  запуск сервера), `detect_hw.ps1` (железо), `autotune.ps1` (подбор `LLM_CTX`,
  `LLM_NGL` и т.д.).

## CI (GitHub Actions) — `.github/workflows/`

- Файлы триггерятся **на push в `main`** (не только по расписанию — автозапуск
  по пушу был целью фикса `67923bb`), на PR и вручную (`workflow_dispatch`).
- Джоб `test-linux.yml`: один шаг — `bash tests/run-all.sh` (ставит pwsh
  через `setup-powershell`). Раннер гоняет `bash -n` + все bash-тесты + все
  PS-тесты под pwsh и даёт сводку с `exit 0/1`.
- Джоб `test-windows.yml`:
  1. `ps-unit` — каждый `tests/*.ps1` отдельным шагом под PowerShell 5.1
     **и** pwsh 7 (шаги развязаны `if: always()`).
  2. `server-smoke` — скачивает llama.cpp (SHA256 pinned), распаковывает и
     запускает `llama-server` с моделью, проверяет `http://127.0.0.1:8080/health`.
- Подробности и конвенции тестов — в `TESTING.md`. Новый тест добавляется в
  `tests/run-all.sh` (или явно в шаги `test-windows.yml` для Windows-only).

## Известные грабли (важно для будущих правок)

- **UTF-8 BOM обязателен** в `Windows.bat` и `*.ps1` для PowerShell 5.1:
  без BOM паpс байнится из-за не-ASCII (коммит `f9df0aa`). Не снимай BOM.
- **Детерминированный автотюн**: юнит-тесты пиннят параметры явно
  (`-VramMB 0 -RamMB 8000`) и ждут `LLM_CTX=2048`. Родительский и унаследованный
  дочерний pwsh могут расходиться по RAM — поэтому в тесте не полагаться на
  динамику (коммит `51b184d`).
- **zip-архивы llama.cpp плоские**: они распаковываются в корень без верхнего
  каталога. Smoke-шаг копирует всю папку `llama-bin` целиком (его
  `llama-server.exe` + все `ggml-*.dll` + `llama-server-impl.dll`) — не только
  один exe (коммит `7c154c1`).
- **Run-With-CrashLog** в `common.ps1`: для получения кода выхода на PS 5.1
  использовать `Start-Process -Wait -PassThru` (а не `WaitForExit`+`Refresh`).
- Инцидент GitHub Actions (webhook-задержки) бывает глобальным — проверять
  по githubstatus.com, прежде чем чинить воркфлоу.
- **Q-факторы моделей — единый источник `lib/quant-factors.tsv`** (формат
  `<glob>\t<factor>`, первое совпадение сверху, case-insensitive). Читается
  и `detect_hw.sh`, и `detect_hw.ps1` — менять ТОЛЬКО таблицу, не дублировать
  формулы в двух местах. Паритет закреплён тестами: `tests/windows-unit.ps1`
  и `tests/linux-unit.sh` дают одинаковые ожидания (округление `%.0f`/`[int]`).
- **Автоподбор контекста по GGUF, а не по таблице**: `estimate_context_model`
  (bash) / `Get-RecommendedContext` (PS) парсят метаданные `.gguf` напрямую
  (`*.context_length`, `block_count`, `head_count_kv`, `head_dim`) и считают
  подходящий `ctx` из фактически свободной памяти: KV = слои×KV-головы×head_dim×4,
  бюджет = свободная память − модель − резерв 768 МБ, `ctx = clamp(бюджет×1MiB/KV, 256, native)`.
  Фолбэк на эвристику `Estimate-Context` — только если GGUF недоступен/не парсится
  (правки `f9df0aa`). `LLM_CTX` из окружения перекрывает автоподбор (не перетирать).
  Паритет тестов: синтетический мини-GGUF встраивается base64-строкой **_одинаково_**
  в `tests/linux-unit.sh` и `tests/windows-unit.ps1` (детерминизм). Юнит-тест
  autotune (`-ModelDir`) указывает на синтетический GGUF во временной папке,
  чтобы результат не зависел от фактических файлов в `models/`.
- **Pinned-хэши в CI**: smoke-шаг проверяет SHA256 скачанных артефактов —
  путь бинарника в `LLAMA_WIN_CPU_SHA256` в `lib/versions.inc` (обновлять при
  апгрейде версии), модель — по LFS-oid Hugging Face. TLS1.2 + `-UseBasicParsing`.
- **rus-локали lscpu печатает искажённое `ID прроизводителя`** (две «р» —
  реальная строка локали util-linux, не опечатка в коде). Матчить общий
  фрагмент `изводител`; в ветке lscpu добавлен fallback на `/proc/cpuinfo`
  (коммит `2d08b2e`).
- **`find_free_port` без ss/netstat** работает через bash `/dev/tcp`-пробу —
  важно для минимальных/busybox-дистрибутивов на «любом ПК» (`e26cfa8`).
- При сбое скачивания в headless-режиме (`--no-ui`/`--silent`) `Lunix.sh`
  НЕ ждёт `Enter` — выходит с кодом 1 (`477ad8c`).

## Интеграция с OpenCode — только глобальный конфиг

- `opencode.json` **не живёт** в этом репо и исключён через `.gitignore`.
- При запуске модели `Lunix.sh`/`Windows.bat` вызывают:
  - Linux: `bash lib/opencode_update.sh <model> <port>` — пишет блок
    `llama-local` в `~/.config/opencode/opencode.json`.
  - Windows: `powershell -File lib\update_opencode.ps1 -Model <model> -Port <port>`
    — пишет в `%USERPROFILE%\.config\opencode\opencode.json`.
- Причина: проектный `opencode.json` имел приоритет над глобальным и мешал
  работе — теперь единый источник — глобальный конфиг (рефакторинг `94992d9`).

## Быстрые команды

```bash
./Lunix.sh                                     # локальный запуск (Linux)
bash tests/run-all.sh                          # все тесты: bash + PS (единый раннер)
bash tests/run-all.sh --bash                   # только bash-тесты
pwsh -f tests/windows-unit.ps1                 # unit-тесты Windows-логики
bash tests/linux-unit.sh                       # unit-тесты Linux-логики
bash -n lib/opencode_update.sh                 # проверка синтаксиса bash
git push origin main                           # пуш запускает CI (push-триггер)
```