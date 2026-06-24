"""
Surveille /data_sources et déclenche WF-04 via webhook n8n quand un fichier change.
Lance avec : python3 data_sources_watcher.py
"""
import time
import logging
import urllib.request
import json
from pathlib import Path
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [WATCHER] %(levelname)s %(message)s"
)
log = logging.getLogger(__name__)

WATCH_PATH = Path("/home/nyanu/Documents/ETL_Projet/data_sources")
N8N_WEBHOOK = "http://localhost:5678/webhook/run-etl-projet"
# Extensions à ignorer (fichiers temporaires)
IGNORE_SUFFIXES = {".tmp", ".part", ".swp", ".swx", "~"}
IGNORE_PREFIXES = {".", "test_event"}

DEBOUNCE_SECONDS = 5  # ignore repeated events within 5s
_last_trigger = 0


def should_ignore(path: str) -> bool:
    p = Path(path)
    if p.suffix in IGNORE_SUFFIXES:
        return True
    if any(p.name.startswith(pref) for pref in IGNORE_PREFIXES):
        return True
    return False


def trigger_wf04(event_type: str, src_path: str):
    global _last_trigger
    now = time.time()
    if now - _last_trigger < DEBOUNCE_SECONDS:
        log.debug("Debounce — skip trigger for %s", src_path)
        return
    _last_trigger = now

    payload = json.dumps({
        "event": event_type,
        "file": src_path,
        "source": "data_sources_watcher"
    }).encode()

    req = urllib.request.Request(
        N8N_WEBHOOK,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            log.info("WF-04 déclenché [%s] %s → HTTP %d", event_type, src_path, resp.status)
    except Exception as e:
        log.error("Echec appel webhook: %s", e)


class DataSourceHandler(FileSystemEventHandler):

    def on_created(self, event):
        if not event.is_directory and not should_ignore(event.src_path):
            log.info("NOUVEAU fichier: %s", event.src_path)
            trigger_wf04("created", event.src_path)

    def on_modified(self, event):
        if not event.is_directory and not should_ignore(event.src_path):
            log.info("MODIFIÉ: %s", event.src_path)
            trigger_wf04("modified", event.src_path)


if __name__ == "__main__":
    log.info("Surveillance de %s → webhook %s", WATCH_PATH, N8N_WEBHOOK)
    observer = Observer()
    observer.schedule(DataSourceHandler(), str(WATCH_PATH), recursive=False)
    observer.start()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()
