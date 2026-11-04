import sqlite3
import os
import json
from datetime import datetime, date
from typing import Dict, Any, List, Optional

DB_FILE = os.path.join(os.path.dirname(__file__), "fit3_database.sqlite")

def get_connection() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_FILE, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn

def init_db():
    conn = get_connection()
    cursor = conn.cursor()

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS steps (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        day_date TEXT UNIQUE,
        steps INTEGER DEFAULT 0,
        calories REAL DEFAULT 0.0,
        distance_meters REAL DEFAULT 0.0,
        active_minutes INTEGER DEFAULT 0,
        timestamp TEXT,
        source TEXT DEFAULT 'Galaxy Fit3 (78DC)'
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS heart_rate (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bpm INTEGER NOT NULL,
        contact INTEGER DEFAULT 1,
        rr_interval_ms INTEGER,
        timestamp TEXT NOT NULL,
        source TEXT DEFAULT 'Galaxy Fit3 (78DC)'
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS sleep_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        day_date TEXT UNIQUE,
        start_time TEXT,
        end_time TEXT,
        deep_minutes INTEGER DEFAULT 0,
        light_minutes INTEGER DEFAULT 0,
        rem_minutes INTEGER DEFAULT 0,
        awake_minutes INTEGER DEFAULT 0,
        sleep_score INTEGER DEFAULT 80,
        timestamp TEXT,
        source TEXT DEFAULT 'Galaxy Fit3 (78DC)'
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS spo2 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        percentage INTEGER NOT NULL,
        timestamp TEXT NOT NULL,
        source TEXT DEFAULT 'Galaxy Fit3 (78DC)'
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS battery (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        level INTEGER NOT NULL,
        timestamp TEXT NOT NULL
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS ble_packets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT NOT NULL,
        service_uuid TEXT,
        char_uuid TEXT,
        direction TEXT DEFAULT 'RX',
        hex_string TEXT,
        raw_bytes_json TEXT,
        decoded_summary TEXT,
        note TEXT
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT
    )
    """)

    conn.commit()
    conn.close()

# MARK: - Ingestion Functions

def save_steps(steps: int, calories: Optional[float] = None, distance: Optional[float] = None, active_minutes: Optional[int] = None, source: str = "Galaxy Fit3 (78DC)"):
    if calories is None:
        calories = round(steps * 0.042, 1)
    if distance is None:
        distance = round(steps * 0.74, 1)
    if active_minutes is None:
        active_minutes = max(0, int(steps / 115))

    today_str = date.today().isoformat()
    now_str = datetime.now().isoformat()

    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("""
    INSERT INTO steps (day_date, steps, calories, distance_meters, active_minutes, timestamp, source)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(day_date) DO UPDATE SET
        steps = excluded.steps,
        calories = excluded.calories,
        distance_meters = excluded.distance_meters,
        active_minutes = excluded.active_minutes,
        timestamp = excluded.timestamp,
        source = excluded.source
    """, (today_str, steps, calories, distance, active_minutes, now_str, source))
    conn.commit()
    conn.close()

def save_heart_rate(bpm: int, contact: bool = True, rr_interval_ms: Optional[int] = None, source: str = "Galaxy Fit3 (78DC)"):
    now_str = datetime.now().isoformat()
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("""
    INSERT INTO heart_rate (bpm, contact, rr_interval_ms, timestamp, source)
    VALUES (?, ?, ?, ?, ?)
    """, (bpm, 1 if contact else 0, rr_interval_ms, now_str, source))
    conn.commit()
    conn.close()

def save_sleep_session(start_time: str, end_time: str, deep: int, light: int, rem: int, awake: int, score: int = 85, source: str = "Galaxy Fit3 (78DC)"):
    today_str = date.today().isoformat()
    now_str = datetime.now().isoformat()
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("""
    INSERT INTO sleep_sessions (day_date, start_time, end_time, deep_minutes, light_minutes, rem_minutes, awake_minutes, sleep_score, timestamp, source)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(day_date) DO UPDATE SET
        start_time = excluded.start_time,
        end_time = excluded.end_time,
        deep_minutes = excluded.deep_minutes,
        light_minutes = excluded.light_minutes,
        rem_minutes = excluded.rem_minutes,
        awake_minutes = excluded.awake_minutes,
        sleep_score = excluded.sleep_score,
        timestamp = excluded.timestamp,
        source = excluded.source
    """, (today_str, start_time, end_time, deep, light, rem, awake, score, now_str, source))
    conn.commit()
    conn.close()

def save_spo2(percentage: int, source: str = "Galaxy Fit3 (78DC)"):
    now_str = datetime.now().isoformat()
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("""
    INSERT INTO spo2 (percentage, timestamp, source)
    VALUES (?, ?, ?)
    """, (percentage, now_str, source))
    conn.commit()
    conn.close()

def save_battery(level: int):
    now_str = datetime.now().isoformat()
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("""
    INSERT INTO battery (level, timestamp)
    VALUES (?, ?)
    """, (level, now_str))
    conn.commit()
    conn.close()

def save_ble_packet(service_uuid: str, char_uuid: str, direction: str, hex_string: str, raw_bytes: list, decoded_summary: str, note: Optional[str] = None):
    now_str = datetime.now().isoformat()
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("""
    INSERT INTO ble_packets (timestamp, service_uuid, char_uuid, direction, hex_string, raw_bytes_json, decoded_summary, note)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, (now_str, service_uuid, char_uuid, direction, hex_string, json.dumps(raw_bytes), decoded_summary, note))
    conn.commit()
def save_setting(key: str, value: str):
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("""
    INSERT INTO settings (key, value)
    VALUES (?, ?)
    ON CONFLICT(key) DO UPDATE SET value = excluded.value
    """, (key, value))
    conn.commit()
    conn.close()

def get_setting(key: str, default: Optional[str] = None) -> Optional[str]:
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT value FROM settings WHERE key = ?", (key,))
    row = cursor.fetchone()
    conn.close()
    if row and row["value"]:
        return row["value"]
    return default

# MARK: - Query Functions

def get_today_summary() -> Dict[str, Any]:
    today_str = date.today().isoformat()
    conn = get_connection()
    cursor = conn.cursor()

    # Steps
    cursor.execute("SELECT * FROM steps WHERE day_date = ?", (today_str,))
    step_row = cursor.fetchone()
    steps_data = dict(step_row) if step_row else {
        "steps": 0,
        "calories": 0.0,
        "distance_meters": 0.0,
        "active_minutes": 0
    }

    # Latest Heart Rate
    cursor.execute("SELECT bpm, timestamp FROM heart_rate ORDER BY id DESC LIMIT 1")
    hr_row = cursor.fetchone()
    latest_hr = hr_row["bpm"] if hr_row else 0
    latest_hr_time = hr_row["timestamp"] if hr_row else None

    # Avg Heart Rate Today
    cursor.execute("SELECT AVG(bpm) as avg_bpm FROM heart_rate WHERE timestamp >= ?", (today_str + "T00:00:00",))
    avg_hr_row = cursor.fetchone()
    avg_hr = int(round(avg_hr_row["avg_bpm"])) if (avg_hr_row and avg_hr_row["avg_bpm"]) else latest_hr

    # Latest Battery
    cursor.execute("SELECT level FROM battery ORDER BY id DESC LIMIT 1")
    bat_row = cursor.fetchone()
    battery_level = bat_row["level"] if bat_row else 85

    # Latest SpO2
    cursor.execute("SELECT percentage FROM spo2 ORDER BY id DESC LIMIT 1")
    spo2_row = cursor.fetchone()
    latest_spo2 = spo2_row["percentage"] if spo2_row else 98

    # Sleep
    cursor.execute("SELECT * FROM sleep_sessions WHERE day_date = ?", (today_str,))
    sleep_row = cursor.fetchone()
    if not sleep_row:
        # Check most recent sleep
        cursor.execute("SELECT * FROM sleep_sessions ORDER BY id DESC LIMIT 1")
        sleep_row = cursor.fetchone()

    sleep_data = dict(sleep_row) if sleep_row else {
        "deep_minutes": 88,
        "light_minutes": 242,
        "rem_minutes": 96,
        "awake_minutes": 22,
        "sleep_score": 87,
        "start_time": f"{today_str}T00:15:00",
        "end_time": f"{today_str}T07:21:00"
    }

    total_sleep_minutes = (sleep_data.get("deep_minutes", 0) +
                          sleep_data.get("light_minutes", 0) +
                          sleep_data.get("rem_minutes", 0))

    # Recent HR points for Chart.js
    cursor.execute("SELECT bpm, timestamp FROM heart_rate ORDER BY id DESC LIMIT 20")
    hr_samples = [dict(r) for r in cursor.fetchall()]
    hr_samples.reverse()

    conn.close()

    return {
        "steps": steps_data.get("steps", 0),
        "calories": steps_data.get("calories", 0.0),
        "distance_meters": steps_data.get("distance_meters", 0.0),
        "active_minutes": steps_data.get("active_minutes", 0),
        "heart_rate_latest": latest_hr,
        "heart_rate_avg": avg_hr,
        "heart_rate_latest_time": latest_hr_time,
        "battery": battery_level,
        "spo2": latest_spo2,
        "sleep": {
            "total_minutes": total_sleep_minutes,
            "deep_minutes": sleep_data.get("deep_minutes", 0),
            "light_minutes": sleep_data.get("light_minutes", 0),
            "rem_minutes": sleep_data.get("rem_minutes", 0),
            "awake_minutes": sleep_data.get("awake_minutes", 0),
            "sleep_score": sleep_data.get("sleep_score", 85),
            "start_time": sleep_data.get("start_time"),
            "end_time": sleep_data.get("end_time")
        },
        "hr_chart": hr_samples
    }

def get_apple_health_payload() -> Dict[str, Any]:
    summary = get_today_summary()
    return {
        "status": "success",
        "device_name": "Galaxy Fit3 (78DC)",
        "model": "SM-R390",
        "date": date.today().isoformat(),
        "exported_at": datetime.now().isoformat(),
        "summary": {
            "steps": summary["steps"],
            "active_calories_kcal": summary["calories"],
            "distance_km": round(summary["distance_meters"] / 1000.0, 2),
            "active_minutes": summary["active_minutes"],
            "heart_rate_latest_bpm": summary["heart_rate_latest"],
            "heart_rate_avg_bpm": summary["heart_rate_avg"],
            "spo2_percent": summary["spo2"],
            "sleep_duration_hours": round(summary["sleep"]["total_minutes"] / 60.0, 2),
            "sleep_score": summary["sleep"]["sleep_score"],
            "battery_percent": summary["battery"]
        },
        "shortcuts_keys": {
            "steps": summary["steps"],
            "heart_rate": summary["heart_rate_latest"],
            "sleep_minutes": summary["sleep"]["total_minutes"],
            "spo2": summary["spo2"]
        }
    }

def get_recent_packets(limit: int = 60) -> List[Dict[str, Any]]:
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM ble_packets ORDER BY id DESC LIMIT ?", (limit,))
    rows = [dict(r) for r in cursor.fetchall()]
    conn.close()
    return rows

def seed_initial_demo_data():
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT COUNT(*) as count FROM steps")
    count = cursor.fetchone()["count"]
    conn.close()

    if count == 0:
        save_steps(steps=6842, calories=287.4, distance=5063.0, active_minutes=54, source="Galaxy Fit3 (78DC) Demo")
        save_battery(86)
        save_spo2(98, source="Galaxy Fit3 (78DC) Demo")

        today_str = date.today().isoformat()
        save_sleep_session(
            start_time=f"{today_str}T00:12:00",
            end_time=f"{today_str}T07:18:00",
            deep=88,
            light=242,
            rem=96,
            awake=22,
            score=87,
            source="Galaxy Fit3 (78DC) Demo"
        )

        base_bpms = [66, 68, 71, 74, 82, 95, 108, 98, 86, 75, 72, 74]
        for bpm in base_bpms:
            save_heart_rate(bpm=bpm, contact=True, rr_interval_ms=int(60000 / bpm), source="Galaxy Fit3 (78DC) Demo")

def export_full_database_dict() -> Dict[str, Any]:
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM steps ORDER BY id DESC")
    steps = [dict(r) for r in cursor.fetchall()]
    cursor.execute("SELECT * FROM heart_rate ORDER BY id DESC LIMIT 500")
    hr = [dict(r) for r in cursor.fetchall()]
    cursor.execute("SELECT * FROM sleep_sessions ORDER BY id DESC")
    sleep = [dict(r) for r in cursor.fetchall()]
    cursor.execute("SELECT * FROM spo2 ORDER BY id DESC LIMIT 100")
    spo2 = [dict(r) for r in cursor.fetchall()]
    cursor.execute("SELECT * FROM battery ORDER BY id DESC LIMIT 100")
    battery = [dict(r) for r in cursor.fetchall()]
    cursor.execute("SELECT * FROM ble_packets ORDER BY id DESC LIMIT 200")
    packets = [dict(r) for r in cursor.fetchall()]
    conn.close()
    return {
        "exported_at": datetime.now().isoformat(),
        "device": "Galaxy Fit3 (78DC)",
        "tables": {
            "steps": steps,
            "heart_rate": hr,
            "sleep_sessions": sleep,
            "spo2": spo2,
            "battery": battery,
            "ble_packets": packets
        }
    }

def export_heart_rate_csv() -> str:
    import io
    import csv
    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT timestamp, bpm, contact, rr_interval_ms, source FROM heart_rate ORDER BY id DESC LIMIT 1000")
    rows = cursor.fetchall()
    conn.close()
    
    output = io.StringIO()
    writer = csv.writer(output)
    writer.writerow(["timestamp", "bpm", "contact", "rr_interval_ms", "source"])
    for r in rows:
        writer.writerow([r["timestamp"], r["bpm"], r["contact"], r["rr_interval_ms"], r["source"]])
    return output.getvalue()

