# ==== Единый источник версий бинарников (single source of truth) ====
# Формат: KEY=VALUE, без BOM. Читается Lunix.sh (bash source) и Windows.bat
# (findstr + fallback). Версии обновлять ТОЛЬКО здесь.
# LLAMA_WIN_CPU_SHA256 — pinned-контрольная сумма zip (SMOKE/CI). При апгрейде
# LLAMA_VERSION обязательно обнови и её (берётся из releases digest).
LLAMA_VERSION=b9932
WHISPER_VERSION=v1.9.2
LLAMA_WIN_CPU_SHA256=1d1ad11bc0b26b6bc9a62fdfbbbd208863e0c078f7bc4c7a467ee6562c13dacd
