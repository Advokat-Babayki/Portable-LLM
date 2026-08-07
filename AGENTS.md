# AGENTS.md — контекст для ИИ-сессий и разработчиков

Этот файл автоматически подхватывает opencode при старте сессии. Здесь —
что где лежит, как всё тестируется и какие грабли уже разгрёбаны. Пользователь
README не читает этот контекст; весь девелоперский бэкграунд живёт здесь.

## Что это

Портативный лаунчер для llama.cpp (LLM) и whisper.cpp (распознавание речи):
- **Linux** — `Lunix.sh` (bash); **Windows** — `Windows.bat` (PowerShell-бутстрап,
  при запуске переписывает себя в cmd-скрипт).
- Бинарники и модели **не хранятся в Git**. При первом запуске скачиваются
  сборки llama.cpp/whisper.cpp из официальных `ggml-org` релизов в `bin/` и
  `whisper/bin/`. Пользователь кладёт `.gguf` (LLM) / `.bin` (Whisper) сам.
- Версии бинарников задаются в переменных `LLAMA_VERSION` / `WHISPER_VERSION`
  в начале `Lunix.sh` и `Windows.bat`.
- Общая Windows-логика вынесена в `lib/*.ps1`: `common.ps1` (порты, краш-логи,
  запуск сервера), `detect_hw.ps1` (железо), `autotune.ps1` (подбор `LLM_CTX`,
  `LLM_NGL` и т.д.).

## CI (GitHub Actions) — `.github/workflows/`

- Файлы названы с префиксом `test-*`/`*hello*` и триггерятся **на push в
  `main`** (не только по расписанию — автозапуск по пушу был целью фикса `67923bb`).
- Джоб `windows-test.yml` делает два шага:
  1. `Unit tests` — `tests/windows-unit.ps1` под PowerShell 5.1 **и** pwsh 7.
  2. `Server smoke` — скачивает llama.cpp, распаковывает и запускает
     `llama-server` с моделью, проверяет `http://127.0.0.1:8080/health`.

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
pwsh -f tests/windows-unit.ps1                 # unit-тесты Windows-логики
bash -n lib/opencode_update.sh                 # проверка синтаксиса bash
git push origin main                           # пуш запускает CI (push-триггер)
```