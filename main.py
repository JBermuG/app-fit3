import os
import socket
import logging
import asyncio
from typing import Optional
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException
from fastapi.responses import FileResponse, JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import database
from ble_manager import BLEManager, HAS_MACOS_COREBLUETOOTH

logger = logging.getLogger("fit3.main")
logging.basicConfig(level=logging.INFO)

# Helper para detectar la IP LAN del Mac
def get_local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('10.255.255.255', 1))
        ip = s.getsockname()[0]
    except Exception:
        ip = '127.0.0.1'
    finally:
        s.close()
    return ip

ble_manager = BLEManager()

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Inicialización en arranque (Sin sembrar datos demo falsos)
    database.init_db()
    database.purge_demo_data()
    logger.info("=" * 60)
    logger.info("🚀 Fit3 Mac Studio iniciado con éxito")
    logger.info("💻 Visualización y recolección de datos en tu Mac:")
    logger.info("   -> http://localhost:8000")
    logger.info("=" * 60)
    
    # Recuperación automática de periféricos ya enlazados a macOS al iniciar
    if HAS_MACOS_COREBLUETOOTH:
        asyncio.create_task(ble_manager.retrieve_connected_peripherals())
    yield
    # Limpieza en apagado
    if ble_manager.client and ble_manager.client.is_connected:
        await ble_manager.disconnect()

app = FastAPI(title="Fit3 Mac Studio - Recolección de Datos BLE", lifespan=lifespan)

# Montar carpeta estática
static_dir = os.path.join(os.path.dirname(__file__), "static")
os.makedirs(static_dir, exist_ok=True)
app.mount("/static", StaticFiles(directory=static_dir), name="static")

# MARK: - Pydantic Request Models

class ConnectRequest(BaseModel):
    address: str

class CharActionRequest(BaseModel):
    uuid: str

class WriteCharRequest(BaseModel):
    uuid: str
    hex_payload: str

class MapCharRequest(BaseModel):
    target: str # steps, heart_rate, sleep
    uuid: str
    offset: Optional[int] = 0
    byte_length: Optional[int] = 4 # 2 para uint16, 4 para uint32

class MockToggleRequest(BaseModel):
    enabled: bool

# MARK: - HTTP Endpoints

@app.get("/")
async def serve_index():
    index_path = os.path.join(static_dir, "index.html")
    if os.path.exists(index_path):
        return FileResponse(index_path)
    return {"message": "Fit3 Mac & iPhone Bridge API online. Coloca index.html en /static."}

@app.get("/api/status")
async def get_status():
    status = ble_manager.get_status()
    status["local_ip"] = get_local_ip()
    status["server_port"] = 8000
    status["iphone_url"] = f"http://{status['local_ip']}:8000"
    return status

@app.post("/api/scan")
async def trigger_scan(timeout: float = 5.0):
    devices = await ble_manager.scan_devices(timeout=timeout)
    return {"status": "success", "count": len(devices), "devices": devices}

@app.post("/api/retrieve-connected")
async def retrieve_connected():
    devices = await ble_manager.retrieve_connected_peripherals()
    return {
        "status": "success",
        "count": len(devices),
        "devices": ble_manager.get_scanned_devices_list(),
        "message": f"Se recuperaron {len(devices)} dispositivos conectados en macOS."
    }

@app.get("/api/devices")
async def list_devices():
    return {"devices": ble_manager.get_scanned_devices_list()}

@app.post("/api/connect")
async def connect_device(req: ConnectRequest):
    try:
        ok = await ble_manager.connect(req.address)
        if not ok:
            raise HTTPException(status_code=400, detail=ble_manager.last_status_message)
        return {"status": "connected", "address": req.address, "name": ble_manager.connected_device_name}
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Excepción en /api/connect: {e}")
        raise HTTPException(status_code=400, detail=str(e))

@app.post("/api/disconnect")
async def disconnect_device():
    await ble_manager.disconnect()
    return {"status": "disconnected"}

@app.get("/api/services")
async def get_services():
    return {"services": ble_manager.discovered_services}

@app.post("/api/characteristics/notify")
async def toggle_notify(req: CharActionRequest):
    if req.uuid in ble_manager.active_subscriptions:
        ok = await ble_manager.stop_notify(req.uuid)
        return {"status": "stopped", "uuid": req.uuid, "success": ok}
    else:
        ok = await ble_manager.start_notify(req.uuid)
        return {"status": "started", "uuid": req.uuid, "success": ok}

@app.post("/api/characteristics/notify-all")
async def notify_all_chars():
    count = await ble_manager.subscribe_all_notifiable()
    return {"status": "success", "subscribed_count": count}

@app.post("/api/characteristics/read")
async def read_char(req: CharActionRequest):
    hex_val = await ble_manager.read_characteristic(req.uuid)
    if hex_val is None:
        raise HTTPException(status_code=400, detail="No se pudo leer la característica o el reloj no está conectado.")
    return {"status": "success", "uuid": req.uuid, "hex_value": hex_val}

@app.post("/api/characteristics/write")
async def write_char(req: WriteCharRequest):
    ok = await ble_manager.write_characteristic(req.uuid, req.hex_payload)
    if not ok:
        raise HTTPException(status_code=400, detail=ble_manager.last_status_message)
    return {"status": "success", "uuid": req.uuid, "hex_payload": req.hex_payload}

@app.post("/api/characteristics/map")
async def map_characteristic(req: MapCharRequest):
    cleaned = req.uuid.upper().strip()
    if req.target == "steps":
        ble_manager.custom_steps_uuid = cleaned
    elif req.target == "heart_rate":
        ble_manager.custom_hr_uuid = cleaned
    elif req.target == "sleep":
        ble_manager.custom_sleep_uuid = cleaned
    else:
        raise HTTPException(status_code=400, detail=f"Objetivo de mapeo '{req.target}' no válido.")

    return {"status": "success", "target": req.target, "uuid": cleaned}

@app.post("/api/mock/toggle")
async def toggle_mock(req: MockToggleRequest):
    await ble_manager.toggle_mock_mode(req.enabled)
    return {"status": "success", "is_mock_mode": ble_manager.is_mock_mode}

@app.get("/api/health/summary")
async def get_health_summary():
    return ble_manager.get_telemetry()

@app.get("/api/apple-health-export")
async def export_apple_health():
    """Endpoint limpio optimizado para la app 'Atajos' de iOS."""
    return database.get_apple_health_payload()

@app.get("/api/ble-logs")
async def get_ble_logs(limit: int = 80):
    return {"logs": database.get_recent_packets(limit=limit)}

@app.get("/api/export/csv")
async def export_csv():
    csv_data = database.export_heart_rate_csv()
    return Response(
        content=csv_data,
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=fit3_heart_rate.csv"}
    )

@app.get("/api/export/json")
async def export_json():
    full_data = database.export_full_database_dict()
    return JSONResponse(
        content=full_data,
        headers={"Content-Disposition": "attachment; filename=fit3_database_backup.json"}
    )

@app.get("/api/data/records")
async def get_data_records():
    return database.export_full_database_dict()

# MARK: - WebSockets Real-Time Stream

@app.websocket("/ws/ble-logs")
async def websocket_logs_endpoint(websocket: WebSocket):
    await websocket.accept()
    await ble_manager.register_websocket(websocket)

    # Enviar estado inicial y últimos paquetes
    try:
        init_payload = {
            "type": "init",
            "status": ble_manager.get_status(),
            "telemetry": ble_manager.get_telemetry(),
            "services": ble_manager.discovered_services,
            "recent_packets": database.get_recent_packets(limit=35)
        }
        await websocket.send_json(init_payload)

        while True:
            # Mantener conexión viva y procesar posibles comandos del frontend
            data = await websocket.receive_text()
            if data == "ping":
                await websocket.send_text("pong")
    except WebSocketDisconnect:
        await ble_manager.unregister_websocket(websocket)
    except Exception as e:
        logger.debug(f"WebSocket cerrado: {e}")
        await ble_manager.unregister_websocket(websocket)
