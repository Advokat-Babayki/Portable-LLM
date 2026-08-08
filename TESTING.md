# Тестирование Portable-LLM

Это инструкция для разработчиков: как запускать тесты, как писать новые
и как подключать их к CI. Краткая справка по «граблям» проекта — в
`AGENTS.md` (дублируется здесь то, что критично для тестов).

## Быстрый запуск

Всё локально, одной командой (нужны `bash` и `pwsh`):

```bash
bash tests/run-all.sh        # все тесты: bash + PS
bash tests/run-all.sh --bash # только bash-тесты
bash tests/run-all.sh --ps   # только PS-тесты
```

Сводка вида `Итог: N/M тестов прошло` и `exit 0/1`. То же самое гоняет
CI в джобе **Linux tests**.

По отдельности:

```bash
bash tests/linux-unit.sh          # unit-логика Linux-модулей (lib/*.sh)
bash tests/opencode-unit.sh       # lib/opencode_update.sh
bash tests/linux-cli-test.sh      # CLI-режим Lunix.sh (стабы железа/бинарников)
bash tests/linux-download-test.sh # ветка скачивания бинарников
pwsh -NoProfile -File tests/windows-unit.ps1      # unit-логика Windows-модулей
pwsh -NoProfile -File tests/opencode-unit.ps1     # lib/update_opencode.ps1
pwsh -NoProfile -File tests/windows-bat-smoke.ps1 # целостность Windows.bat
```

`windows-*` и `opencode-unit.ps1` работают и на Linux (pwsh), но **только
на Windows** проверяется PowerShell 5.1 — это делает CI.

## Структура

```
tests/
├── run-all.sh              # единый раннер (bash + pwsh)
├── lib/                    # ОБЩАЯ ИНФРАСТРУКТУРА для тестов
│   ├── bash-assert.sh      # assert_eq / assert_true / test_done (bash)
│   ├── bash-sandbox.sh     # песочница Lunix.sh: стабы железа, бинарников,
│   │                       #   скачивания; install_launcher / run_cli
│   └── ps-test.ps1         # Assert-Equal / Assert-True / Exit-Tests (PS, с BOM)
├── linux-unit.sh           # паритет Linux-логики с Windows-ожиданиями
├── linux-cli-test.sh       # интеграция CLI Lunix.sh
├── linux-download-test.sh  # ensure_binaries / download_binaries
├── opencode-unit.sh        # bash: обновление opencode.json
├── opencode-unit.ps1       # PS:   то же (зеркало)
├── windows-unit.ps1        # паритет Windows-логики (detect_hw/autotune/crash)
└── windows-bat-smoke.ps1   # целостность Windows.bat
```

## Конвенции

1. **Детерминизм.** Тесты не должны зависеть от реального железа, сети или
   случайностей. Всё «железо» — PATH-стабы (`lscpu/free/vulkaninfo/ss`),
   скачивание — стабы `curl/wget/tar/stat`. Библиотека `bash-sandbox.sh`
   задаёт готовые профили: `cpu` (RAM 128 GiB) и `vulkan` (VRAM 60 GiB).
2. **Песочница.** Интеграционные тесты копируют `Lunix.sh` + `lib/` в
   временную папку (`install_launcher`). Репозиторий не трогается.
3. **Выходной код.** Успех — `exit 0`, любое падение — `exit 1`. Тест
   обязан завершиться сам (`test_done` / `Exit-Tests`), не «провалиться» в
   неопределённом состоянии.
4. **BOM для PS.** Каждый `*.ps1` — в UTF-8 с BOM (иначе Windows PowerShell
   5.1 ломается на кириллице; грабли `f9df0aa`). Библиотека и тесты уже так
   записаны — не снимай BOM при правках.
5. **`set -u`** в начале bash-теста — ловим необъявленные переменные.
6. **Общие хелперы — только через `tests/lib/`**, не копипастить.

## Как написать новый тест

Скопируй заготовку ниже, заполни секции. Где взять хелперы — см. таблицу:

| Хочешь                | Используй                        |
|---|---|
| сравнение значений    | `assert_eq <expected> <actual> <name>` |
| условие/код возврата  | `assert_true <0\|true> <name>`         |
| проверить файл        | `assert_file <path> <name>`            |
| grep в файле          | `assert_grep <ere> <file> <name>`      |
| итог + exit           | `test_done` (bash) / `Exit-Tests` (PS) |
| песочница Lunix.sh    | `make_hw_stubs`, `make_bin_stubs`, `make_dl_stubs`, `install_launcher`, `run_cli` |

### Bash-тест (заготовка)

```bash
#!/bin/bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

source "$ROOT/tests/lib/bash-assert.sh"
# source "$ROOT/tests/lib/bash-sandbox.sh"   # если нужна песочница

echo "=== Мой сценарий ==="
assert_eq "expected" "$(cmd)" "что проверяем"
assert_true "$([ -f "$WORK/x" ]; echo $?)" "файл создан"

test_done
```

### PS-тест (заготовка)

```powershell
# помни: файл в UTF-8 с BOM
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'lib\ps-test.ps1')

Write-Host "=== Мой сценарий ==="
Assert-Equal "expected" (cmd) 'что проверяем'
Assert-True (Test-Path 'x') 'файл создан'

Exit-Tests
```

## Как подключить тест к CI

CI живёт в `.github/workflows/` и запускается **на push в `main`** (пуш-триггер),
на PR и вручную (`workflow_dispatch`).

1. **Добавь тест в раннер** `tests/run-all.sh`:
   - bash-тест → массив `BASH_TESTS`;
   - ps1-тест → массив `PS_TESTS`.
2. **Linux CI** (`.github/workflows/test-linux.yml`): джоба `bash-unit`
   вызывает `bash tests/run-all.sh` — новый bash-тест попадёт туда
   автоматически. Проверь, что файл покрыт `bash -n` (шаг синтаксиса
   использует `tests/run-all.sh` → все `tests/*.sh` и `tests/lib/*.sh`).
3. **Windows CI** (`.github/workflows/test-windows.yml`): джоба `ps-unit`
   перечисляет PS-тесты явно (PowerShell 5.1 + pwsh 7) — добавь новый
   ps1-файл в оба шага.
4. Если тест требует Windows (например, запуск реального `llama-server.exe`)
   — добавляй в `server-smoke`, не в `ps-unit`.

### Обновление версий бинарников

Версии — единый источник `lib/versions.inc`. Тесты (`linux-download-test.sh`,
`windows-bat-smoke.ps1`) проверяют, что URL и fallback-значения согласованы
с этим файлом. При апгрейде версии **обязательно** обнови `LLAMA_VERSION` /
`WHISPER_VERSION` там и, при необходимости, pinned-хэш
`LLAMA_WIN_CPU_SHA256` (см. `AGENTS.md`).

## Типовые проблемы

- **BOM потерян** → PS-тест на Windows 5.1 падает с мусором в тексте.
  Верни BOM (первые 3 байта `EF BB BF`).
- **`cp -r lib $sandbox/lib` создаёт `lib/lib`** → `install_launcher` в
  `bash-sandbox.sh` уже делает `rm -rf` перед копированием. Не «упрощай».
- **Тест лезет в сеть / на железо** → значит стабы не сработали. Проверь,
  что `run_cli` (или твой запуск) подставляет stub-каталог в `PATH` первым.
