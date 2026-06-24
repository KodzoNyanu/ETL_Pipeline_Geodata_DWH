"""
ETL Runner — Micro-service HTTP qui déclenche Apache Hop via Docker CLI.
Exposé sur le réseau Docker (port 9999), appelé par n8n WF-05 Orchestrateur.
"""
import subprocess, json, logging, os
from http.server import BaseHTTPRequestHandler, HTTPServer
from datetime import datetime

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [ETL-RUNNER] %(levelname)s %(message)s'
)
log = logging.getLogger(__name__)

HOP_CONTAINER  = os.getenv("HOP_CONTAINER",  "transform_hop")
HOP_PROJECT    = os.getenv("HOP_PROJECT",    "ETL_Projet")
HOP_WORKFLOW   = os.getenv("HOP_WORKFLOW",   "/project/workflows/main_etl_gold.hwf")
HOP_RUN_CONFIG = os.getenv("HOP_RUN_CONFIG", "local")


class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        log.info(fmt % args)

    def _json(self, code: int, body: dict):
        payload = json.dumps(body, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path == "/health":
            self._json(200, {"status": "ok", "ts": datetime.utcnow().isoformat()})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/run-etl":
            self._json(404, {"error": "use POST /run-etl"})
            return

        log.info("🚀 Déclenchement Apache Hop — workflow: %s", HOP_WORKFLOW)
        started = datetime.utcnow().isoformat()
        try:
            result = subprocess.run(
                [
                    "docker", "exec", HOP_CONTAINER,
                    "/usr/local/tomcat/webapps/ROOT/hop-run.sh",
                    "--project", HOP_PROJECT,
                    "-r", HOP_RUN_CONFIG,
                    "-f", HOP_WORKFLOW,
                ],
                capture_output=True, text=True, timeout=7200
            )
            success = result.returncode == 0
            log.info("✅ Hop terminé (rc=%d)", result.returncode) if success \
                else log.error("❌ Hop en erreur (rc=%d)\n%s", result.returncode, result.stderr[-500:])

            self._json(200 if success else 500, {
                "status":     "success" if success else "error",
                "returncode": result.returncode,
                "started_at": started,
                "ended_at":   datetime.utcnow().isoformat(),
                "stdout_tail": result.stdout[-3000:],
                "stderr_tail": result.stderr[-500:],
            })
        except subprocess.TimeoutExpired:
            log.error("⏱️ Timeout — Hop a dépassé 2h")
            self._json(504, {"status": "timeout", "message": "Hop > 2h"})
        except Exception as exc:
            log.exception("Erreur inattendue")
            self._json(500, {"status": "error", "message": str(exc)})


if __name__ == "__main__":
    port = int(os.getenv("PORT", 9999))
    log.info("ETL Runner démarré sur :%d", port)
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
# Note: La route /run-pipeline est disponible pour des tests unitaires
