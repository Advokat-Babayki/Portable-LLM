# ==== Единый источник версий бинарников (single source of truth) ====
# Формат: KEY=VALUE, без BOM. Читается Lunix.sh (bash source) и Windows.bat
# (findstr + fallback). Версии обновлять ТОЛЬКО здесь.
# LLAMA_WIN_CPU_SHA256 — pinned-контрольная сумма zip (SMOKE/CI). При апгрейде
# LLAMA_VERSION обязательно обнови и её (берётся из releases digest).
# LLAMA_TEST_MODEL_SHA256 — pinned-контрольная сумма тестовой модели
# qwen2.5-coder-0.5b-instruct-q4_k_m.gguf (используется в server-smoke CI-джобах обеих ОС).
# Обновлять при замене тестовой модели.
# Аналогичные *_SHA256 для Linux-бинарников — такие же pinned-контрольные суммы.
# При обновлении версии: скачай архив, посчитай `sha256sum`, обнови здесь.
LLAMA_VERSION=b9932
WHISPER_VERSION=v1.9.2
LLAMA_WIN_CPU_SHA256=1d1ad11bc0b26b6bc9a62fdfbbbd208863e0c078f7bc4c7a467ee6562c13dacd
LLAMA_TEST_MODEL_SHA256=1d9614638d18024d0fbb36575a15f1302a3adf044df10345688ec4f6e1c4ff32

# Linux pinned-хэши (sha256sum архивов .tar.gz). Заполняются при релиз-апгрейде.
# Пока пусты — SHA256-проверка на Linux пропускается (не блокирует запуск).
LLAMA_LINUX_CPU_SHA256=
LLAMA_LINUX_VK_SHA256=
WHISPER_LINUX_CPU_SHA256=
