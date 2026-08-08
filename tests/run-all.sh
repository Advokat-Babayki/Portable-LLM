#!/bin/bash
# =====================================================
# run-all.sh — единый раннер всех тестов проекта.
# Запускает bash-тесты (Linux-логика) и PS-тесты (через pwsh),
# в конце печатает сводку PASS/FAIL и выходит с кодом 0/1.
#
# Использование:
#   bash tests/run-all.sh            — все тесты
#   bash tests/run-all.sh --bash     — только bash-тесты
#   bash tests/run-all.sh --ps       — только PS-тесты
#
# Требования: bash, pwsh (PowerShell Core) в PATH.
# В CI это ровно то же, что джоба Linux tests (test-linux.yml).
# =====================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

BASH_TESTS=(
    tests/linux-unit.sh
    tests/opencode-unit.sh
    tests/linux-cli-test.sh
    tests/linux-download-test.sh
)

PS_TESTS=(
    tests/opencode-unit.ps1
    tests/windows-unit.ps1
    tests/windows-bat-smoke.ps1
)

MODE="all"
[ "${1:-}" = "--bash" ] && MODE="bash"
[ "${1:-}" = "--ps" ]   && MODE="ps"

TOTAL=0
FAILED=0
declare -a FAILED_NAMES=()

run_one() { # $1 имя, $2 команда...
    local name="$1"; shift
    TOTAL=$((TOTAL+1))
    printf '%-28s ' "[$name]"
    if "$@" >"$WORK/out.log" 2>&1; then
        echo "PASS"
    else
        echo "FAIL"
        FAILED=$((FAILED+1))
        FAILED_NAMES+=("$name")
    fi
}

# -------- синтаксис ---------
run_one "bash -n (lib+scripts)" bash -n Lunix.sh lib/*.sh tests/lib/*.sh tests/*.sh

if [ "$MODE" != "ps" ]; then
    for t in "${BASH_TESTS[@]}"; do
        run_one "$t" bash "$t"
    done
fi

if [ "$MODE" != "bash" ]; then
    if ! command -v pwsh >/dev/null 2>&1; then
        echo ""
        echo "[!] pwsh не найден — PS-тесты пропущены (установите PowerShell Core)"
    else
        for t in "${PS_TESTS[@]}"; do
            run_one "$t" pwsh -NoProfile -File "$t"
        done
    fi
fi

echo ""
echo "====================="
echo "Итог: $((TOTAL-FAILED))/$TOTAL тестов прошло"
if [ "$FAILED" -gt 0 ]; then
    echo "Упали: ${FAILED_NAMES[*]}"
    exit 1
fi
echo "Все тесты прошли."
exit 0
