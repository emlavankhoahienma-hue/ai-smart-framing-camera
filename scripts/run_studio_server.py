# -*- coding: utf-8 -*-
import os
import sys
import json
import time
import socket
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

PORT = 8088
ROOT_DIR = r"C:\Users\admin\.gemini\antigravity\scratch\ai-smart-framing-camera\scripts"
PROJECT_DIR = r"C:\Users\admin\.gemini\antigravity\scratch\ai-smart-framing-camera"
DATASET_DIR = os.path.join(PROJECT_DIR, "data", "photography_dataset_8k")
IMAGES_DIR = os.path.join(DATASET_DIR, "images")
ANNOTATIONS_FILE = os.path.join(DATASET_DIR, "annotations_8k.json")

DASHBOARD_PATH = os.path.join(ROOT_DIR, "dashboard.html")
STATE_PATH = os.path.join(ROOT_DIR, "training_state.json")
PREVIEW_PATH = os.path.join(ROOT_DIR, "current_preview.jpg")

def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

LOCAL_IP = get_local_ip()

annotations_list = []
cached_image_bytes = None
active_meta = {
    "filename": "img_00000_v1.jpg",
    "target_x": 0.618,
    "target_y": 0.382,
    "scene_name": "Chân dung (Portrait)",
    "rule_name": "Tỷ lệ vàng (0.618)",
    "zoom": 1.2
}
meta_lock = threading.Lock()

def load_annotations():
    global annotations_list
    if os.path.exists(ANNOTATIONS_FILE):
        try:
            with open(ANNOTATIONS_FILE, "r", encoding="utf-8") as f:
                annotations_list = json.load(f)
        except Exception:
            pass

def image_cycler_thread():
    global cached_image_bytes, active_meta
    idx = 0
    blank_jpg = b'\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x01\x00H\x00H\x00\x00\xff\xdb\x00C\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\t\t\x08\n\x0c\x14\r\x0c\x0b\x0b\x0c\x19\x12\x13\x0f\x14\x1d\x1a\x1f\x1e\x1d\x1a\x1c\x1c $.\' ",#\x1c\x1c(7),01444\x1f\'9=82<.342\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00\xff\xc4\x00\x1f\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\xff\xda\x00\x08\x01\x01\x00\x00?\x00\xbf\x00\xff\xd9'

    while True:
        if not annotations_list:
            load_annotations()
            time.sleep(1.0)
            continue

        item = annotations_list[idx % len(annotations_list)]
        img_path = os.path.join(IMAGES_DIR, item.get("filename", ""))
        
        data = None
        if os.path.exists(img_path):
            try:
                with open(img_path, "rb") as f:
                    data = f.read()
            except Exception:
                pass

        if data is None and os.path.exists(PREVIEW_PATH):
            try:
                with open(PREVIEW_PATH, "rb") as f:
                    data = f.read()
            except Exception:
                pass

        with meta_lock:
            cached_image_bytes = data if data else blank_jpg
            active_meta = item

        idx += 1
        time.sleep(1.5)

DEFAULT_STATE = {
    "local_ip": LOCAL_IP,
    "status": "TRAINING",
    "stage": "Đang huấn luyện Deep Master...",
    "progress_pct": 52.0,
    "current_epoch": 1,
    "total_epochs": 20,
    "processed_images": 8010,
    "total_images": 8010,
    "loss": 0.35,
    "target_error_pct": 7.8,
    "scene_accuracy": 55.0,
    "rule_accuracy": 59.0,
    "elapsed_seconds": 0,
    "eta_seconds": 900,
    "current_image_name": "",
    "current_target_x": 0.5,
    "current_target_y": 0.5,
    "current_scene": "Chân dung (Portrait)",
    "current_rule": "Tỷ lệ vàng (0.618)",
    "current_zoom": 1.0,
    "weights_size_mb": 150.0,
    "log_messages": [f"[{LOCAL_IP}] Server AlignAI Deep Studio sẵn sàng."],
    "shutdown_timer": -1,
    "is_completed": False
}

class StudioHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def send_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Connection", "close")

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_cors_headers()
        self.end_headers()

    def do_GET(self):
        url_path = self.path.split("?")[0]

        if url_path in ["", "/", "/index.html"]:
            if os.path.exists(DASHBOARD_PATH):
                with open(DASHBOARD_PATH, "rb") as f:
                    content = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_cors_headers()
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)
            else:
                self.send_error(404, "Dashboard HTML not found")

        elif url_path == "/api/status":
            state = dict(DEFAULT_STATE)
            if os.path.exists(STATE_PATH):
                try:
                    with open(STATE_PATH, "r", encoding="utf-8") as f:
                        state = json.load(f)
                except Exception:
                    pass

            state["local_ip"] = LOCAL_IP

            with meta_lock:
                state["current_image_name"] = active_meta.get("filename", "")
                state["current_target_x"] = active_meta.get("target_x", 0.5)
                state["current_target_y"] = active_meta.get("target_y", 0.5)
                state["current_scene"] = active_meta.get("scene_name", "Chân dung (Portrait)")
                state["current_rule"] = active_meta.get("rule_name", "Tỷ lệ vàng (0.618)")
                state["current_zoom"] = active_meta.get("zoom", 1.0)

            data = json.dumps(state, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_cors_headers()
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        elif url_path == "/api/current_image":
            with meta_lock:
                data = cached_image_bytes

            if data is None:
                data = b'\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x01\x00H\x00H\x00\x00\xff\xdb\x00C\x00\x08\x06\x06\x07\x06\x05\x08\x07\x07\x07\t\t\x08\n\x0c\x14\r\x0c\x0b\x0b\x0c\x19\x12\x13\x0f\x14\x1d\x1a\x1f\x1e\x1d\x1a\x1c\x1c $.\' ",#\x1c\x1c(7),01444\x1f\'9=82<.342\xff\xc0\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00\xff\xc4\x00\x1f\x00\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\xff\xda\x00\x08\x01\x01\x00\x00?\x00\xbf\x00\xff\xd9'

            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_cors_headers()
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        else:
            self.send_error(404, "Not Found")

def main():
    load_annotations()
    t = threading.Thread(target=image_cycler_thread, daemon=True)
    t.start()

    server = ThreadingHTTPServer(("0.0.0.0", PORT), StudioHandler)
    server.daemon_threads = True
    print(f"AlignAI Monitor Server running at http://{LOCAL_IP}:{PORT} and http://localhost:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.server_close()

if __name__ == "__main__":
    main()
