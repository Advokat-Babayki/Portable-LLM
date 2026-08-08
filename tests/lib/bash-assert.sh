#!/bin/bash
# =====================================================
# bash-assert.sh — общая библиотека ассертов для bash-тестов.
# Подключается: source "${ROOT}/tests/lib/bash-assert.sh"
#
# Даёт:
#   assert_eq <expected> <actual> <name>   — сравнение строк
#   assert_true <cond> <name>              — cond = 0 (успех) или строка
#   assert_file <path> <name>              — файл существует
#   assert_grep <pattern> <file> <name>    — паттерн найден в файле
#   test_done                              — вывод итога + exit 0/1
#
# Переменная $FAILURES накапливает число падений.
# =====================================================

: "${FAILURES:=0}"

# Сравнение значений. $1 expected, $2 actual, $3 имя теста.
assert_eq() {
    if [ "$1" != "$2" ]; then
        FAILURES=$((FAILURES+1))
        echo "FAIL: $3 — ожидал '$1', получил '$2'"
    else
        echo "OK:   $3 = '$2'"
    fi
}

# Проверка условия: $1 = код возврата (0 — успех) или строка "true".
assert_true() {
    if [ "$1" != "0" ] && [ "$1" != true ]; then
        FAILURES=$((FAILURES+1))
        echo "FAIL: $2"
    else
        echo "OK:   $2"
    fi
}

# Файл существует: $1 путь, $2 имя теста.
assert_file() {
    if [ -e "$1" ]; then
        echo "OK:   $2"
    else
        FAILURES=$((FAILURES+1))
        echo "FAIL: $2 — файл не найден: $1"
    fi
}

# Grep-паттерн в файле: $1 паттерн (ERE), $2 файл, $3 имя теста.
assert_grep() {
    if grep -qE "$1" "$2" 2>/dev/null; then
        echo "OK:   $3"
    else
        FAILURES=$((FAILURES+1))
        echo "FAIL: $3 — паттерн '$1' не найден в $2"
    fi
}

# Итог: выводит PASS/FAILURES и завершает скрипт.
test_done() {
    echo ""
    if [ "$FAILURES" -gt 0 ]; then
        echo "FAILURES: $FAILURES"
        exit 1
    fi
    echo "ALL TESTS PASSED"
    exit 0
}
