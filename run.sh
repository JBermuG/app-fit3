#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "=========================================================="
echo "          🚀 Iniciando Fit3 Mac Studio                    "
echo "    Samsung Galaxy Fit 3 (SM-R390) • BLE macOS Monterey   "
echo "=========================================================="

# 1. Comprobar Python 3
if ! command -v python3 &> /dev/null; then
    echo "❌ Error: Python 3 no está instalado en este Mac."
    exit 1
fi

# 2. Crear entorno virtual si no existe
if [ ! -d "venv" ]; then
    echo "📦 Creando entorno virtual 'venv' en Python 3..."
    python3 -m venv venv
fi

# 3. Activar venv e instalar dependencias
echo "🔄 Verificando librerías (FastAPI, Bleak, Uvicorn)..."
venv/bin/pip install -r requirements.txt --quiet

echo ""
echo "✅ Servidor preparado para recolectar y visualizar métricas:"
echo "   💻 Panel en tu Mac:  http://localhost:8000"
echo "=========================================================="
echo ""

# 5. Abrir la app en el navegador del Mac en segundo plano
(sleep 1.5 && open "http://localhost:8000" 2>/dev/null || true) &

# 6. Lanzar servidor FastAPI escuchando en 0.0.0.0:8000
exec venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000 --reload
