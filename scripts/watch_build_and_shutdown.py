import json
import subprocess
import time
import sys
from datetime import datetime

RUN_ID = "39175940628"
POLL_INTERVAL_SEC = 25
SHUTDOWN_TIMEOUT_SEC = 60

def get_run_status(run_id: str):
    try:
        proc = subprocess.run(
            ["gh", "run", "view", run_id, "--json", "status,conclusion,url"],
            capture_output=True,
            text=True,
            encoding="utf-8"
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return json.loads(proc.stdout)
    except Exception as e:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] Loi khi lay thong tin run: {e}", flush=True)
    return None

def main():
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Bat dau theo doi GitHub Actions run: {RUN_ID}", flush=True)
    
    while True:
        info = get_run_status(RUN_ID)
        now_str = datetime.now().strftime("%H:%M:%S")
        
        if info:
            status = info.get("status")
            conclusion = info.get("conclusion")
            url = info.get("url")
            print(f"[{now_str}] Status: {status} | Conclusion: {conclusion} | URL: {url}", flush=True)
            
            if status == "completed":
                print(f"[{now_str}] Build da hoan tat voi ket qua: {conclusion}!", flush=True)
                comment = f"GitHub Actions build hoan tat ({conclusion}). He thong se tat trong {SHUTDOWN_TIMEOUT_SEC}s. Nhap 'shutdown /a' de huy."
                print(f"[{now_str}] Goi lenh tat may: shutdown /s /t {SHUTDOWN_TIMEOUT_SEC}", flush=True)
                
                # Goi lenh tat may
                subprocess.run(["shutdown", "/s", "/t", str(SHUTDOWN_TIMEOUT_SEC), "/c", comment])
                print(f"[{now_str}] Lenh shutdown da duoc len lich thanh cong. Thoat watcher.", flush=True)
                break
        else:
            print(f"[{now_str}] Chua lay duoc trang thai, thu lai sau {POLL_INTERVAL_SEC}s...", flush=True)
            
        time.sleep(POLL_INTERVAL_SEC)

if __name__ == "__main__":
    main()
