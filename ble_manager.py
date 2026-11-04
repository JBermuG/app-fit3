import asyncio
import logging
import traceback
from typing import Dict, Any, List, Optional, Set
from datetime import datetime
import json

from bleak import BleakScanner, BleakClient
from bleak.backends.characteristic import BleakGATTCharacteristic
from bleak.backends.device import BLEDevice

# Importación condicional de CoreBluetooth para macOS
try:
    from CoreBluetooth import (
        CBUUID,
        CBPeripheral,
        CBPeripheralStateConnected,
    )
    from Foundation import NSUUID, NSArray
    from bleak.backends.corebluetooth.CentralManagerDelegate import CentralManagerDelegate
    HAS_MACOS_COREBLUETOOTH = True
except ImportError:
    HAS_MACOS_COREBLUETOOTH = False

import database

logger = logging.getLogger("fit3.ble_manager")
logging.basicConfig(level=logging.INFO)

# MARK: - Constants & UUIDs
STANDARD_UUIDS = {
    "180d": "Heart Rate Service",
    "2a37": "Heart Rate Measurement",
    "2a38": "Body Sensor Location",
    "180f": "Battery Service",
    "2a19": "Battery Level",
    "180a": "Device Information Service",
    "2a29": "Manufacturer Name",
    "2a24": "Model Number",
    "2a26": "Firmware Revision",
    "1814": "Running Speed & Cadence",
    "2a53": "RSC Measurement",
    "1802": "Immediate Alert",
    "2a06": "Alert Level"
}

# UUIDs de servicios típicos de wearables / Samsung para retrieveConnectedPeripherals
CONNECTED_QUERY_SERVICES = [
    "180D", "180F", "180A", "1812", "1800", "1801", "1814",
    "FEEE", "FD59", "FD69", "FD5A", "FEE7", "FEE0", "FEE1"
]

def normalize_uuid(uuid_str: str) -> str:
    cleaned = uuid_str.lower().strip()
    if cleaned.startswith("0000") and cleaned.endswith("-0000-1000-8000-00805f9b34fb"):
        return cleaned[4:8]
    return cleaned

class BLEManager:
    HAS_MACOS_COREBLUETOOTH: bool = HAS_MACOS_COREBLUETOOTH

    def __init__(self):
        self.HAS_MACOS_COREBLUETOOTH = HAS_MACOS_COREBLUETOOTH
        self.has_macos_corebluetooth = HAS_MACOS_COREBLUETOOTH
        self.client: Optional[BleakClient] = None
        self.connected_device_address: Optional[str] = None
        self.connected_device_name: str = "Sin vincular"
        self.connection_state: str = "disconnected" # disconnected, scanning, connecting, connected, simulating
        self.last_status_message: str = "Listo para conectar con tu Samsung Galaxy Fit 3"

        # Cache de objetos BLEDevice reales (CRÍTICO para macOS CoreBluetooth)
        self.discovered_devices: Dict[str, BLEDevice] = {}
        self.scanned_devices: Dict[str, Dict[str, Any]] = {}
        self.discovered_services: List[Dict[str, Any]] = []
        self.active_subscriptions: Set[str] = set()

        # Manager de CoreBluetooth persistente
        self._manager: Optional[Any] = None
        self._active_peripheral: Optional[Any] = None
        self._connect_lock = asyncio.Lock()

        # Telemetría actual
        self.battery_level: int = 86
        self.current_hr: int = 74
        self.today_steps: int = 6842
        self.today_calories: float = 287.4
        self.today_distance: float = 5063.0
        self.today_active_minutes: int = 54
        self.current_spo2: int = 98
        self.device_model: str = "SM-R390"
        self.device_manufacturer: str = "Samsung Electronics"
        self.device_firmware: str = "R390XXU0AXB4"
        self.last_rssi: int = -51

        # Mapeos dinámicos configurables por el usuario para ingeniería inversa
        self.custom_steps_uuid: str = "FEA1"
        self.custom_hr_uuid: str = "2A37"
        self.custom_sleep_uuid: str = "FEA2"

        # Modo Simulación
        self.is_mock_mode: bool = False
        self._mock_task: Optional[asyncio.Task] = None
        self._reconnect_task: Optional[asyncio.Task] = None

        # Clientes WebSocket conectados
        self.websocket_clients: Set[Any] = set()

        # Inicializar métricas desde SQLite
        self._load_initial_metrics()

    def _load_initial_metrics(self):
        summary = database.get_today_summary()
        self.today_steps = summary.get("steps", 0)
        self.today_calories = summary.get("calories", 0.0)
        self.today_distance = summary.get("distance_meters", 0.0)
        self.today_active_minutes = summary.get("active_minutes", 0)
        if summary.get("heart_rate_latest"):
            self.current_hr = summary["heart_rate_latest"]
        if summary.get("battery"):
            self.battery_level = summary["battery"]
        if summary.get("spo2"):
            self.current_spo2 = summary["spo2"]

    # MARK: - CoreBluetooth Manager Helper (macOS Native)

    async def _get_central_manager(self) -> Optional[Any]:
        """Obtiene o inicializa el CentralManagerDelegate de CoreBluetooth en macOS."""
        if not HAS_MACOS_COREBLUETOOTH:
            return None
        if self._manager is None:
            try:
                self._manager = CentralManagerDelegate()
                await self._manager.wait_until_ready()
            except Exception as e:
                logger.warning(f"No se pudo inicializar CentralManagerDelegate: {e}")
                return None
        else:
            try:
                await self._manager.wait_until_ready()
            except Exception:
                pass
        return self._manager

    # MARK: - WebSocket Broadcasting

    async def register_websocket(self, ws: Any):
        self.websocket_clients.add(ws)

    async def unregister_websocket(self, ws: Any):
        self.websocket_clients.discard(ws)

    async def broadcast_event(self, event_type: str, data: Any):
        if not self.websocket_clients:
            return
        payload = json.dumps({"type": event_type, "data": data, "timestamp": datetime.now().isoformat()})
        disconnected = set()
        for ws in self.websocket_clients:
            try:
                await ws.send_text(payload)
            except Exception:
                disconnected.add(ws)
        self.websocket_clients.difference_update(disconnected)

    # MARK: - Recuperar Reloj Ya Conectado al Mac (macOS Native)

    async def retrieve_connected_peripherals(self) -> List[BLEDevice]:
        """
        Consulta directamente a CoreBluetooth por periféricos que YA están conectados
        o enlazados a macOS Monterey, permitiendo conectar inmediatamente a la Galaxy Fit3 (78DC)
        incluso si ha dejado de emitir anuncios BLE.
        """
        if not HAS_MACOS_COREBLUETOOTH:
            return []

        manager = await self._get_central_manager()
        if not manager or not hasattr(manager, "central_manager"):
            return []

        retrieved_list: List[BLEDevice] = []
        seen_addresses: Set[str] = set()

        # 1. retrieveConnectedPeripheralsWithServices_
        try:
            cbuuids = [CBUUID.UUIDWithString_(s) for s in CONNECTED_QUERY_SERVICES]
            connected_peripherals = manager.central_manager.retrieveConnectedPeripheralsWithServices_(cbuuids)
            if connected_peripherals:
                for p in connected_peripherals:
                    addr = str(p.identifier().UUIDString())
                    if addr in seen_addresses:
                        continue
                    seen_addresses.add(addr)
                    raw_name = str(p.name()) if p.name() else "Galaxy Fit3 (78DC)"
                    is_connected = (p.state() == CBPeripheralStateConnected)
                    
                    # Construir objeto BLEDevice real con details = (CBPeripheral, CentralManagerDelegate)
                    device_obj = BLEDevice(
                        address=addr,
                        name=raw_name,
                        details=(p, manager)
                    )
                    self.discovered_devices[addr] = device_obj
                    retrieved_list.append(device_obj)

                    upper_name = raw_name.upper()
                    is_fit3 = (
                        "FIT3" in upper_name
                        or "78DC" in upper_name
                        or "SM-R390" in upper_name
                        or "GALAXY" in upper_name
                        or "SAMSUNG" in upper_name
                    )

                    self.scanned_devices[addr] = {
                        "address": addr,
                        "name": raw_name,
                        "rssi": -45 if is_connected else -58,
                        "is_fit3": is_fit3,
                        "is_connected_system": is_connected,
                        "system_status": "Ya conectado a macOS" if is_connected else "Enlazado en el Mac",
                        "services": ["180D", "180F", "FD5A"],
                        "last_seen": datetime.now().isoformat()
                    }
                    logger.info(f"✅ Periférico recuperado de CoreBluetooth: {raw_name} ({addr}) - Estado: {is_connected}")
        except Exception as e:
            logger.warning(f"Error en retrieveConnectedPeripheralsWithServices_: {e}")

        # 2. retrievePeripheralsWithIdentifiers_ usando UUID guardado previamente
        saved_uuid = database.get_setting("last_fit3_uuid")
        if saved_uuid and saved_uuid not in seen_addresses:
            try:
                nsuuid = NSUUID.alloc().initWithUUIDString_(saved_uuid)
                if nsuuid:
                    known_peripherals = manager.central_manager.retrievePeripheralsWithIdentifiers_([nsuuid])
                    if known_peripherals:
                        for p in known_peripherals:
                            addr = str(p.identifier().UUIDString())
                            if addr in seen_addresses:
                                continue
                            seen_addresses.add(addr)
                            saved_name = database.get_setting("last_fit3_name", "Galaxy Fit3 (78DC)")
                            raw_name = str(p.name()) if p.name() else saved_name
                            is_connected = (p.state() == CBPeripheralStateConnected)

                            device_obj = BLEDevice(
                                address=addr,
                                name=raw_name,
                                details=(p, manager)
                            )
                            self.discovered_devices[addr] = device_obj
                            retrieved_list.append(device_obj)

                            self.scanned_devices[addr] = {
                                "address": addr,
                                "name": raw_name,
                                "rssi": -45 if is_connected else -60,
                                "is_fit3": True,
                                "is_connected_system": is_connected,
                                "system_status": "Ya conectado a macOS" if is_connected else "Enlazado previamente",
                                "services": ["180D", "180F", "FD5A"],
                                "last_seen": datetime.now().isoformat()
                            }
                            logger.info(f"✅ Periférico recuperado por NSUUID guardado: {raw_name} ({addr})")
            except Exception as e:
                logger.debug(f"Error en retrievePeripheralsWithIdentifiers_: {e}")

        return retrieved_list

    # MARK: - BLE Scanning

    async def scan_devices(self, timeout: float = 5.0) -> List[Dict[str, Any]]:
        if self.is_mock_mode:
            return self.get_scanned_devices_list()

        self.connection_state = "scanning"
        self.last_status_message = "Escaneando dispositivos BLE cercanos..."
        await self.broadcast_event("status_update", self.get_status())

        # Limpiar lista anterior para no acumular datos obsoletos
        self.scanned_devices.clear()
        self.discovered_devices.clear()

        # PASO A: Recuperar periféricos que ya están conectados o guardados en macOS
        retrieved_mac = await self.retrieve_connected_peripherals()
        if retrieved_mac:
            self.last_status_message = f"Se detectó {len(retrieved_mac)} reloj/dispositivo ya enlazado al Mac. Escaneando anuncios..."
            await self.broadcast_event("status_update", self.get_status())

        # PASO B: Escaneo estándar de anuncios activos con BleakScanner
        try:
            discovered = await BleakScanner.discover(timeout=timeout, return_adv=True)
            for address, (device, adv_data) in discovered.items():
                # Guardar el objeto BLEDevice real en cache
                self.discovered_devices[address] = device

                name = device.name or adv_data.local_name or "Desconocido"
                upper_name = name.upper()
                is_fit3 = (
                    "FIT3" in upper_name
                    or "78DC" in upper_name
                    or "SM-R390" in upper_name
                    or "GALAXY" in upper_name
                    or "SAMSUNG" in upper_name
                )
                service_uuids = [normalize_uuid(u) for u in adv_data.service_uuids]

                # Si ya existía por retrieveConnectedPeripherals, preservar su marca de conexión
                prev = self.scanned_devices.get(address)
                is_conn_sys = prev.get("is_connected_system", False) if prev else False

                self.scanned_devices[address] = {
                    "address": address,
                    "name": name,
                    "rssi": adv_data.rssi if adv_data.rssi is not None else -70,
                    "is_fit3": is_fit3 or (prev.get("is_fit3", False) if prev else False),
                    "is_connected_system": is_conn_sys,
                    "system_status": "Ya conectado a macOS" if is_conn_sys else "Anunciando vía BLE",
                    "services": service_uuids or (prev.get("services", []) if prev else []),
                    "last_seen": datetime.now().isoformat()
                }

            self.connection_state = "connected" if (self.client and self.client.is_connected) else "disconnected"
            self.last_status_message = f"Escaneo completado. {len(self.scanned_devices)} dispositivos encontrados."
        except Exception as e:
            logger.error(f"Aviso durante escaneo de anuncios: {e}")
            self.connection_state = "connected" if (self.client and self.client.is_connected) else "disconnected"
            self.last_status_message = f"Escaneo finalizado ({len(self.scanned_devices)} dispositivos listos)."

        await self.broadcast_event("status_update", self.get_status())
        return self.get_scanned_devices_list()

    def get_scanned_devices_list(self) -> List[Dict[str, Any]]:
        devices: List[Dict[str, Any]] = []
        for d in self.scanned_devices.values():
            addr = d.get("address", "")
            # REGLA 3: Si el modo simulación está apagado, jamás mostrar dispositivos con direcciones mock
            if not self.is_mock_mode:
                if "MOCK" in addr or addr.startswith("AA:BB") or addr == "F9:A2:78:DC:39:00":
                    continue
            devices.append(d)

        # Destacar al inicio:
        # 1. Periféricos ya conectados a macOS
        # 2. Periféricos Galaxy Fit3
        # 3. Mayor RSSI
        devices.sort(key=lambda d: (
            not d.get("is_connected_system", False),
            not d.get("is_fit3", False),
            -d.get("rssi", -100)
        ))
        return devices

    # MARK: - Connection Management (Pass Real BLEDevice)

    async def connect(self, address: str) -> bool:
        async with self._connect_lock:
            if self.is_mock_mode:
                await self.toggle_mock_mode(False)

            # Si ya estamos conectados a esta misma dirección, retornar éxito inmediato
            if self.client and self.client.is_connected and self.connected_device_address == address:
                logger.info(f"Ya conectado previamente a {address}.")
                return True

            if self._reconnect_task:
                self._reconnect_task.cancel()
                self._reconnect_task = None

            if self.client and self.client.is_connected:
                await self.disconnect()

            # REGLA 1: Obtener el objeto BLEDevice real cacheado
            ble_device = self.discovered_devices.get(address)

            # Si no estaba en cache (por ejemplo, tras reinicio), intentar recuperarlo nativamente vía CoreBluetooth
            if ble_device is None:
                logger.info(f"Buscando BLEDevice para {address} mediante CoreBluetooth...")
                await self.retrieve_connected_peripherals()
                ble_device = self.discovered_devices.get(address)

            if ble_device is None:
                err = f"No se encontró el objeto BLEDevice para '{address}'. Ejecuta un escaneo primero."
                logger.error(err)
                self.last_status_message = err
                await self.broadcast_event("status_update", self.get_status())
                raise Exception(err)

            self.connection_state = "connecting"
            device_name = ble_device.name or self.scanned_devices.get(address, {}).get("name", "Galaxy Fit3 (78DC)")
            self.last_status_message = f"Conectando a {device_name} ({address})..."
            await self.broadcast_event("status_update", self.get_status())

            def on_disconnect(client: Any = None):
                addr = getattr(client, "address", address) if client else address
                logger.warning(f"Periférico {addr} desconectado.")
                if self.connection_state == "connected":
                    self.connection_state = "disconnected"
                    self.last_status_message = "Conexión perdida con el reloj. Intentando reconexión..."
                    asyncio.create_task(self.broadcast_event("status_update", self.get_status()))
                    if not self._reconnect_task or self._reconnect_task.done():
                        self._reconnect_task = asyncio.create_task(self._auto_reconnect_loop(address))

            try:
                logger.info(f"Instanciando BleakClient con BLEDevice real: {ble_device} (details={ble_device.details})")
                
                # CRÍTICO: Referencia fuerte al CBPeripheral en la clase para evitar recolección por ARC/PyObjC
                if ble_device.details and isinstance(ble_device.details, tuple):
                    self._active_peripheral = ble_device.details[0]

                self.client = BleakClient(
                    ble_device,
                    disconnected_callback=on_disconnect,
                    timeout=20.0
                )
                
                # CRÍTICO: En Bleak 1.0+, connect() retorna None (no booleano) si tiene éxito y lanza excepción si falla.
                await self.client.connect()
                
                # Validar estado mediante is_connected
                if self.client.is_connected:
                    self.connected_device_address = address
                    self.connected_device_name = device_name
                    self.connection_state = "connected"
                    self.last_status_message = f"Conectado a {self.connected_device_name}. Enumerando servicios GATT..."
                    logger.info(f"✅ Conexión exitosa con {self.connected_device_name} ({address})")
                    
                    # Guardar UUID en base de datos para recuperación automática instantánea
                    database.save_setting("last_fit3_uuid", address)
                    database.save_setting("last_fit3_name", device_name)

                    await self.broadcast_event("status_update", self.get_status())

                    # Enumerar servicios y características
                    await self._discover_gatt_services()

                    # Suscripción automática a Heart Rate y Batería si están disponibles
                    await self._auto_subscribe_essential_services()

                    return True
                else:
                    raise Exception("El cliente BLE no confirmó el estado conectado (is_connected=False).")
            except Exception as e:
                tb = traceback.format_exc()
                logger.error(f"❌ Error detallado al conectar con {address}:\n{tb}")
                self.connection_state = "disconnected"
                self._active_peripheral = None
                if self.client:
                    try:
                        await self.client.disconnect()
                    except Exception:
                        pass
                    self.client = None
                
                raw_err = str(e) or type(e).__name__
                hint = ""
                lower_err = raw_err.lower()
                if "denied" in lower_err or "unauthorized" in lower_err:
                    hint = " [Permiso denegado: Ve a Ajustes del Sistema > Privacidad y Seguridad > Bluetooth y habilita Terminal / Python]"
                elif "not found" in lower_err:
                    hint = " [Dispositivo no encontrado en BLE: Asegúrate de que el reloj esté encendido o enlazado al Mac]"

                self.last_status_message = f"Error al conectar: {raw_err}{hint}"
                await self.broadcast_event("status_update", self.get_status())
                raise Exception(self.last_status_message)

    async def disconnect(self):
        if self._reconnect_task:
            self._reconnect_task.cancel()
            self._reconnect_task = None

        if self.client:
            try:
                if self.client.is_connected:
                    await self.client.disconnect()
            except Exception as e:
                logger.debug(f"Aviso al desconectar: {e}")
            finally:
                self.client = None

        self._active_peripheral = None
        self.connected_device_address = None
        self.connection_state = "disconnected"
        self.active_subscriptions.clear()
        self.last_status_message = "Reloj desconectado."
        await self.broadcast_event("status_update", self.get_status())

    async def _auto_reconnect_loop(self, address: str):
        """Intenta reconectar automáticamente si el reloj se aleja y vuelve."""
        retry_interval = 4.0
        while self.connection_state == "disconnected" and not self.is_mock_mode:
            logger.info(f"Reintentando conexión con {address}...")
            self.last_status_message = "Buscando Galaxy Fit 3 para reconexión automática..."
            await self.broadcast_event("status_update", self.get_status())
            try:
                # Primero recuperar de CoreBluetooth
                await self.retrieve_connected_peripherals()
                if address in self.discovered_devices:
                    ok = await self.connect(address)
                    if ok:
                        logger.info("Reconexión automática exitosa!")
                        return
            except Exception as e:
                logger.debug(f"Fallo temporal en reconexión: {e}")
            await asyncio.sleep(retry_interval)

    # MARK: - GATT Discovery & Subscriptions

    async def _discover_gatt_services(self):
        if not self.client or not self.client.is_connected:
            return

        self.discovered_services.clear()
        services = self.client.services

        for service in services:
            short_s_uuid = normalize_uuid(service.uuid)
            s_name = STANDARD_UUIDS.get(short_s_uuid, f"Servicio Propietario ({short_s_uuid.upper()})")
            is_proprietary = short_s_uuid not in STANDARD_UUIDS

            chars_info = []
            for char in service.characteristics:
                short_c_uuid = normalize_uuid(char.uuid)
                c_name = STANDARD_UUIDS.get(short_c_uuid, f"Característica {short_c_uuid.upper()}")
                props = char.properties

                can_read = "read" in props
                can_write = ("write" in props) or ("write-without-response" in props)
                can_notify = ("notify" in props) or ("indicate" in props)

                # Si es una característica estándar segura de información, leer su valor inicial
                if can_read and short_c_uuid in ["2a00", "2a19", "2a24", "2a26", "2a29", "2a38"]:
                    try:
                        val = await asyncio.wait_for(self.client.read_gatt_char(char.uuid), timeout=1.5)
                        last_hex = val.hex().upper()
                        self._process_characteristic_data(service.uuid, char.uuid, val, direction="RX", note="Lectura inicial")
                    except Exception as e:
                        logger.debug(f"Lectura inicial omitida para {char.uuid}: {e}")

                chars_info.append({
                    "service_uuid": service.uuid,
                    "uuid": char.uuid,
                    "short_uuid": short_c_uuid.upper(),
                    "name": c_name,
                    "properties": props,
                    "can_read": can_read,
                    "can_write": can_write,
                    "can_notify": can_notify,
                    "is_notifying": char.uuid in self.active_subscriptions,
                    "last_hex": last_hex
                })

            self.discovered_services.append({
                "uuid": service.uuid,
                "short_uuid": short_s_uuid.upper(),
                "name": s_name,
                "is_proprietary": is_proprietary,
                "characteristics": chars_info
            })

        self.last_status_message = f"GATT listo ({len(self.discovered_services)} servicios enumerados)."
        await self.broadcast_event("services_discovered", self.discovered_services)

    async def _auto_subscribe_essential_services(self):
        """Activa notificaciones automáticas en Heart Rate y Battery si están disponibles."""
        for s in self.discovered_services:
            for c in s["characteristics"]:
                short = c["short_uuid"].lower()
                if c["can_notify"] and short in ["2a37", "2a19", "2a53"]:
                    await self.start_notify(c["uuid"])

    async def start_notify(self, char_uuid: str) -> bool:
        if not self.client or not self.client.is_connected:
            return False

        def notification_handler(sender: BleakGATTCharacteristic, data: bytearray):
            raw = bytes(data)
            self._process_characteristic_data(
                service_uuid=sender.service_uuid if hasattr(sender, "service_uuid") else "Unknown",
                char_uuid=sender.uuid,
                data=raw,
                direction="RX",
                note="Notificación en vivo"
            )

        try:
            await self.client.start_notify(char_uuid, notification_handler)
            self.active_subscriptions.add(char_uuid)
            self._update_char_notify_state(char_uuid, True)
            self.last_status_message = f"Suscripción activa para {char_uuid}."
            await self.broadcast_event("status_update", self.get_status())
            return True
        except Exception as e:
            logger.error(f"Error al suscribir notificaciones en {char_uuid}: {e}")
            return False

    async def stop_notify(self, char_uuid: str) -> bool:
        if not self.client or not self.client.is_connected:
            return False
        try:
            await self.client.stop_notify(char_uuid)
            self.active_subscriptions.discard(char_uuid)
            self._update_char_notify_state(char_uuid, False)
            self.last_status_message = f"Suscripción detenida en {char_uuid}."
            await self.broadcast_event("status_update", self.get_status())
            return True
        except Exception as e:
            logger.error(f"Error al detener notificación {char_uuid}: {e}")
            return False

    async def subscribe_all_notifiable(self) -> int:
        subscribed_count = 0
        for s in self.discovered_services:
            for c in s["characteristics"]:
                if c["can_notify"] and c["uuid"] not in self.active_subscriptions:
                    ok = await self.start_notify(c["uuid"])
                    if ok:
                        subscribed_count += 1
                        await asyncio.sleep(0.1)
        self.last_status_message = f"Se activó notificación en {subscribed_count} características."
        await self.broadcast_event("status_update", self.get_status())
        return subscribed_count

    async def read_characteristic(self, char_uuid: str) -> Optional[str]:
        if not self.client or not self.client.is_connected:
            return None
        try:
            val = await self.client.read_gatt_char(char_uuid)
            raw = bytes(val)
            self._process_characteristic_data(service_uuid="ReadCmd", char_uuid=char_uuid, data=raw, direction="RX", note="Lectura manual")
            return raw.hex().upper()
        except Exception as e:
            logger.error(f"Error al leer característica {char_uuid}: {e}")
            return None

    async def write_characteristic(self, char_uuid: str, hex_string: str) -> bool:
        cleaned_hex = hex_string.replace("0x", "").replace(" ", "").replace("-", "")
        try:
            data = bytes.fromhex(cleaned_hex)
        except ValueError:
            self.last_status_message = "Formato Hexadecimal inválido."
            return False

        if self.is_mock_mode:
            self._process_characteristic_data("MockService", char_uuid, data, direction="TX", note="Envío manual simulado")
            self.last_status_message = f"TX simulado ({len(data)} bytes) hacia {char_uuid}."
            await self.broadcast_event("status_update", self.get_status())
            return True

        if not self.client or not self.client.is_connected:
            self.last_status_message = "Reloj no conectado para escribir."
            return False

        try:
            await self.client.write_gatt_char(char_uuid, data)
            self._process_characteristic_data("CustomCmd", char_uuid, data, direction="TX", note="Envío manual Hex")
            self.last_status_message = f"Enviados {len(data)} bytes a {char_uuid}."
            await self.broadcast_event("status_update", self.get_status())
            return True
        except Exception as e:
            logger.error(f"Error al escribir en {char_uuid}: {e}")
            self.last_status_message = f"Error al escribir: {str(e)}"
            return False

    def _update_char_notify_state(self, char_uuid: str, is_notifying: bool):
        for s in self.discovered_services:
            for c in s["characteristics"]:
                if c["uuid"] == char_uuid:
                    c["is_notifying"] = is_notifying

    # MARK: - Packet Parsing & Reverse Engineering

    def _process_characteristic_data(self, service_uuid: str, char_uuid: str, data: bytes, direction: str = "RX", note: Optional[str] = None):
        if not data:
            return

        byte_list = list(data)
        hex_str = " ".join(f"{b:02X}" for b in byte_list)
        short_c = normalize_uuid(char_uuid).upper()

        decoded_summary = self._decode_little_endian(byte_list)

        # 1. Heart Rate GATT Estándar (0x2A37)
        if short_c == "2A37" or short_c == self.custom_hr_uuid.upper():
            flags = byte_list[0]
            is_16bit = (flags & 0x01) != 0
            contact = bool(flags & 0x02)
            bpm = 0
            offset = 1
            if is_16bit and len(byte_list) >= 3:
                bpm = byte_list[1] | (byte_list[2] << 8)
                offset = 3
            elif len(byte_list) >= 2:
                bpm = byte_list[1]
                offset = 2

            rr_ms = None
            if (flags & 0x10) and len(byte_list) >= offset + 2:
                raw_rr = byte_list[offset] | (byte_list[offset + 1] << 8)
                rr_ms = int((raw_rr / 1024.0) * 1000.0)

            if 30 <= bpm <= 240:
                self.current_hr = bpm
                database.save_heart_rate(bpm=bpm, contact=contact, rr_interval_ms=rr_ms)
                note = f"Pulso: {bpm} BPM"

        # 2. Battery Service GATT (0x2A19)
        elif short_c == "2A19":
            level = byte_list[0]
            self.battery_level = min(max(level, 0), 100)
            database.save_battery(self.battery_level)
            note = f"Batería: {self.battery_level}%"

        # 3. Device Info (0x2A24 / 0x2A26 / 0x2A29)
        elif short_c == "2A24":
            self.device_model = data.decode(errors="ignore").strip()
            note = f"Modelo: {self.device_model}"
        elif short_c == "2A26":
            self.device_firmware = data.decode(errors="ignore").strip()
            note = f"Firmware: {self.device_firmware}"
        elif short_c == "2A29":
            self.device_manufacturer = data.decode(errors="ignore").strip()
            note = f"Fabricante: {self.device_firmware}"

        # 4. Mapeo Heurístico o Propietario Samsung de Pasos (FE A1 ... o UUID asignado)
        elif (short_c == self.custom_steps_uuid.upper()) or (len(byte_list) >= 6 and byte_list[0] == 0xFE and byte_list[1] == 0xA1):
            offset = 2 if (byte_list[0] == 0xFE and byte_list[1] == 0xA1) else 0
            if len(byte_list) >= offset + 4:
                steps = (
                    byte_list[offset]
                    | (byte_list[offset + 1] << 8)
                    | (byte_list[offset + 2] << 16)
                    | (byte_list[offset + 3] << 24)
                )
                if 0 <= steps <= 150000:
                    self.today_steps = steps
                    self.today_calories = round(steps * 0.042, 1)
                    self.today_distance = round(steps * 0.74, 1)
                    self.today_active_minutes = max(self.today_active_minutes, int(steps / 115))
                    database.save_steps(
                        steps=self.today_steps,
                        calories=self.today_calories,
                        distance=self.today_distance,
                        active_minutes=self.today_active_minutes
                    )
                    note = f"Pasos decodificados: {self.today_steps}"

        # 5. Mapeo Heurístico de Fases de Sueño (FE A2 ...)
        elif (short_c == self.custom_sleep_uuid.upper()) or (len(byte_list) >= 6 and byte_list[0] == 0xFE and byte_list[1] == 0xA2):
            offset = 2 if (byte_list[0] == 0xFE and byte_list[1] == 0xA2) else 0
            if len(byte_list) >= offset + 4:
                deep = byte_list[offset]
                light = byte_list[offset + 1] * 2
                rem = byte_list[offset + 2]
                awake = byte_list[offset + 3]
                now_date = datetime.now().strftime("%Y-%m-%d")
                database.save_sleep_session(
                    start_time=f"{now_date}T00:15:00",
                    end_time=f"{now_date}T07:20:00",
                    deep=deep,
                    light=light,
                    rem=rem,
                    awake=awake,
                    score=min(98, 65 + int(deep / 4))
                )
                note = f"Sueño RX: Prof {deep}m / Lig {light}m / REM {rem}m"

        # 6. SpO2 Heurístico (FE A3 ...)
        elif len(byte_list) >= 3 and byte_list[0] == 0xFE and byte_list[1] == 0xA3:
            spo2 = byte_list[2]
            if 85 <= spo2 <= 100:
                self.current_spo2 = spo2
                database.save_spo2(spo2)
                note = f"SpO2: {spo2}%"

        # Guardar paquete en SQLite
        database.save_ble_packet(
            service_uuid=service_uuid,
            char_uuid=char_uuid,
            direction=direction,
            hex_string=hex_str,
            raw_bytes=byte_list,
            decoded_summary=decoded_summary,
            note=note
        )

        for s in self.discovered_services:
            for c in s["characteristics"]:
                if c["uuid"] == char_uuid:
                    c["last_hex"] = hex_str

        packet_payload = {
            "timestamp": datetime.now().strftime("%H:%M:%S.%f")[:-3],
            "service_uuid": service_uuid,
            "char_uuid": char_uuid,
            "short_uuid": short_c,
            "direction": direction,
            "hex_string": hex_str,
            "raw_bytes": byte_list,
            "utf8_preview": self._bytes_to_utf8(byte_list),
            "decoded_summary": decoded_summary,
            "note": note
        }
        asyncio.create_task(self.broadcast_event("ble_packet", packet_payload))
        asyncio.create_task(self.broadcast_event("telemetry_update", self.get_telemetry()))

    def _decode_little_endian(self, bytes_arr: List[int]) -> str:
        if not bytes_arr:
            return "Vacío"
        parts = [f"u8[0]={bytes_arr[0]}"]
        if len(bytes_arr) >= 2:
            u16_0 = bytes_arr[0] | (bytes_arr[1] << 8)
            parts.append(f"u16LE[0]={u16_0}")
        if len(bytes_arr) >= 4:
            u16_2 = bytes_arr[2] | (bytes_arr[3] << 8)
            u32_0 = bytes_arr[0] | (bytes_arr[1] << 8) | (bytes_arr[2] << 16) | (bytes_arr[3] << 24)
            parts.append(f"u16LE[2]={u16_2}")
            parts.append(f"u32LE[0]={u32_0}")
        return " | ".join(parts)

    def _bytes_to_utf8(self, bytes_arr: List[int]) -> str:
        chars = [chr(b) if 32 <= b <= 126 else "." for b in bytes_arr]
        return "".join(chars)

    # MARK: - Mock Mode Simulation

    async def toggle_mock_mode(self, enabled: bool):
        self.is_mock_mode = enabled
        if enabled:
            if self.client and self.client.is_connected:
                await self.disconnect()

            self.connection_state = "simulating"
            self.connected_device_name = "Galaxy Fit3 (78DC)"
            self.device_model = "SM-R390"
            self.device_manufacturer = "Samsung Electronics"
            self.device_firmware = "R390XXU0AXB4"
            self.battery_level = 86
            self.last_status_message = "Modo Simulación activo: Generando telemetría realista y tramas BLE."

            self._setup_mock_services()

            if not self._mock_task or self._mock_task.done():
                self._mock_task = asyncio.create_task(self._mock_tick_loop())
        else:
            if self._mock_task:
                self._mock_task.cancel()
                self._mock_task = None

            # Limpiar entradas simuladas
            self.scanned_devices = {k: v for k, v in self.scanned_devices.items() if not k.startswith("MOCK")}
            self.connection_state = "disconnected"
            self.connected_device_name = "Sin vincular"
            self.last_status_message = "Modo Simulación desactivado. Listo para conectar con hardware físico."

        await self.broadcast_event("status_update", self.get_status())
        await self.broadcast_event("telemetry_update", self.get_telemetry())

    def _setup_mock_services(self):
        self.discovered_services = [
            {
                "uuid": "0000180d-0000-1000-8000-00805f9b34fb",
                "short_uuid": "180D",
                "name": "Heart Rate Service",
                "is_proprietary": False,
                "characteristics": [
                    {
                        "service_uuid": "0000180d-0000-1000-8000-00805f9b34fb",
                        "uuid": "00002a37-0000-1000-8000-00805f9b34fb",
                        "short_uuid": "2A37",
                        "name": "Heart Rate Measurement",
                        "properties": ["notify"],
                        "can_read": False,
                        "can_write": False,
                        "can_notify": True,
                        "is_notifying": True,
                        "last_hex": "16 4A E8 03"
                    }
                ]
            },
            {
                "uuid": "0000180f-0000-1000-8000-00805f9b34fb",
                "short_uuid": "180F",
                "name": "Battery Service",
                "is_proprietary": False,
                "characteristics": [
                    {
                        "service_uuid": "0000180f-0000-1000-8000-00805f9b34fb",
                        "uuid": "00002a19-0000-1000-8000-00805f9b34fb",
                        "short_uuid": "2A19",
                        "name": "Battery Level",
                        "properties": ["read", "notify"],
                        "can_read": True,
                        "can_write": False,
                        "can_notify": True,
                        "is_notifying": True,
                        "last_hex": "56"
                    }
                ]
            },
            {
                "uuid": "0000fd5a-0000-1000-8000-00805f9b34fb",
                "short_uuid": "FD5A",
                "name": "Samsung Wearable Health Bus (Propietario)",
                "is_proprietary": True,
                "characteristics": [
                    {
                        "service_uuid": "0000fd5a-0000-1000-8000-00805f9b34fb",
                        "uuid": "0000fea1-0000-1000-8000-00805f9b34fb",
                        "short_uuid": "FEA1",
                        "name": "Samsung Pedometer & Calories Frame",
                        "properties": ["read", "write", "notify"],
                        "can_read": True,
                        "can_write": True,
                        "can_notify": True,
                        "is_notifying": True,
                        "last_hex": "FE A1 BA 1A 00 00"
                    },
                    {
                        "service_uuid": "0000fd5a-0000-1000-8000-00805f9b34fb",
                        "uuid": "0000fea2-0000-1000-8000-00805f9b34fb",
                        "short_uuid": "FEA2",
                        "name": "Samsung Sleep Stages Telemetry",
                        "properties": ["read", "notify"],
                        "can_read": True,
                        "can_write": False,
                        "can_notify": True,
                        "is_notifying": True,
                        "last_hex": "FE A2 58 79 60 16"
                    }
                ]
            }
        ]

    async def _mock_tick_loop(self):
        import random
        while self.is_mock_mode:
            await asyncio.sleep(3.0)
            if not self.is_mock_mode:
                break

            delta_hr = random.randint(-3, 4)
            self.current_hr = min(max(self.current_hr + delta_hr, 62), 126)
            rr_raw = int((60.0 / self.current_hr) * 1024)
            hr_frame = bytes([0x16, self.current_hr, rr_raw & 0xFF, (rr_raw >> 8) & 0xFF])
            self._process_characteristic_data("0000180d-0000-1000-8000-00805f9b34fb", "00002a37-0000-1000-8000-00805f9b34fb", hr_frame)

            added_steps = random.randint(4, 16)
            self.today_steps += added_steps
            new_s = self.today_steps
            steps_frame = bytes([
                0xFE, 0xA1,
                new_s & 0xFF,
                (new_s >> 8) & 0xFF,
                (new_s >> 16) & 0xFF,
                (new_s >> 24) & 0xFF
            ])
            self._process_characteristic_data("0000fd5a-0000-1000-8000-00805f9b34fb", "0000fea1-0000-1000-8000-00805f9b34fb", steps_frame)

    # MARK: - Status & Telemetry DTOs

    def get_status(self) -> Dict[str, Any]:
        return {
            "connection_state": self.connection_state,
            "connected_device_name": self.connected_device_name,
            "connected_device_address": self.connected_device_address,
            "battery_level": self.battery_level,
            "last_status_message": self.last_status_message,
            "is_mock_mode": self.is_mock_mode,
            "device_info": {
                "model": self.device_model,
                "manufacturer": self.device_manufacturer,
                "firmware": self.device_firmware,
                "rssi": self.last_rssi
            },
            "active_subscriptions_count": len(self.active_subscriptions)
        }

    def get_telemetry(self) -> Dict[str, Any]:
        summary = database.get_today_summary()
        return {
            "steps": self.today_steps,
            "calories": self.today_calories,
            "distance_meters": self.today_distance,
            "active_minutes": self.today_active_minutes,
            "heart_rate_latest": self.current_hr,
            "heart_rate_avg": summary.get("heart_rate_avg", self.current_hr),
            "battery": self.battery_level,
            "spo2": self.current_spo2,
            "sleep": summary.get("sleep", {}),
            "hr_chart": summary.get("hr_chart", [])
        }
