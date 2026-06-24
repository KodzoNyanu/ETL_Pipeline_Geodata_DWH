# Annexes — Scripts du Projet ETL
**Rapport ETL Projet** | Auteur : Nyanu K. | Date : 2026-06-20

---

## Table des annexes

| Annexe | Fichier | Rôle |
|--------|---------|------|
| A | `docker-compose.yml` | Infrastructure Docker (5 services) |
| B | Code nodes n8n — CDC MD5 | Scripts JavaScript d'ingestion et de détection de changements |
| C | `etl_runner/app.py` | Micro-service Python déclenchant Apache Hop |
| D | `hop_start.sh` | Script de démarrage Apache Hop + serveur API Java |
| E | `workflows/main_etl.hwf` | Orchestration principale Bronze→Silver→Gold |
| F | `workflows/main_etl_silver.hwf` | Orchestration couche Silver (6 pipelines) |
| G | `pipelines/silver/01_silver_clients.hpl` | Pipeline Silver — nettoyage clients |
| H | `pipelines/gold/01_dim_date.hpl` | Pipeline Gold — dimension date |

---

## Annexe A — Infrastructure Docker (`docker-compose.yml`)

Ce fichier définit les 5 services Docker du pipeline ETL, leur réseau interne,
et les volumes partagés entre les conteneurs.

```yaml
# ═══════════════════════════════════════════════════════════════
#  ETL_Projet — Docker Compose
# ═══════════════════════════════════════════════════════════════

networks:
  etl_network:
    driver: bridge
    name: etl_network
    ipam:
      config:
        - subnet: 172.18.0.0/16
          gateway: 172.18.0.1

services:

  # ─── MinIO — Data Lake Bronze ────────────────────────────────
  minio:
    image: minio/minio:latest
    container_name: datalake_minio
    ports:
      - "9000:9000"
      - "9001:9001"
    volumes:
      - /home/nyanu/Documents/ETL_Projet/minio/data:/data
    environment:
      MINIO_ROOT_USER: nyanu
      MINIO_ROOT_PASSWORD: nyanu1234
    command: server /data --console-address ":9001"
    restart: unless-stopped
    networks:
      etl_network:
        ipv4_address: 172.18.0.3
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 10s

  # ─── n8n — Orchestrateur d'ingestion ─────────────────────────
  n8n:
    image: docker.n8n.io/n8nio/n8n:latest
    container_name: ingestion_n8n
    ports:
      - "5678:5678"
    volumes:
      - /home/nyanu/Documents/ETL_Projet/n8n_data:/home/node/.n8n
      - /home/nyanu/Documents/ETL_Projet/data_sources:/data_sources
      - /home/nyanu/Documents/ETL_Projet/staging:/staging
    extra_hosts:
      - "host.docker.internal:host-gateway"
      - "bc2025:10.14.210.119"
    environment:
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - NODE_ENV=production
      - N8N_ENCRYPTION_KEY=nyanu_secret_key_99
      - WEBHOOK_URL=http://localhost:5678/
      - GENERIC_TIMEZONE=Europe/Paris
      - TZ=Europe/Paris
      # Requis pour les Code nodes utilisant fs, crypto, pg
      - NODE_FUNCTION_ALLOW_BUILTIN=fs,path,crypto,os,http,https,net
      - NODE_FUNCTION_ALLOW_EXTERNAL=pg
      - N8N_NODE_FUNCTION_TIMEOUT=1800000
      - N8N_RUNNERS_TASK_TIMEOUT=3600
      - N8N_BLOCK_ENV_ACCESS_IN_NODE=false
      - N8N_RUNNERS_MAX_OLD_SPACE_SIZE=512
    restart: unless-stopped
    networks:
      etl_network:
        ipv4_address: 172.18.0.5
    depends_on:
      minio:
        condition: service_healthy

  # ─── Apache Hop Web — Transformation Silver/Gold ────────────
  apache-hop:
    image: apache/hop-web:latest
    container_name: transform_hop
    ports:
      - "8080:8080"
    volumes:
      - /home/nyanu/Documents/ETL_Projet/apache_hop_data:/project
      - /home/nyanu/Documents/ETL_Projet/staging:/staging
      - /home/nyanu/Documents/ETL_Projet/hop_start.sh:/hop_start.sh:ro
    entrypoint: ["/bin/bash", "/hop_start.sh"]
    environment:
      - HOP_PROJECT_NAME=ETL_Projet
      - HOP_PROJECT_FOLDER=/project
      - HOP_PROJECT_CONFIG_FILE_NAME=project-config.json
      - HOP_ENVIRONMENT_NAME=local
      - HOP_LOG_LEVEL=Basic
      - HOP_WEB_THEME=light
    restart: unless-stopped
    networks:
      etl_network:
        ipv4_address: 172.18.0.2

  # ─── PostgreSQL Gold — Data Warehouse cible ──────────────────
  postgres_gold:
    image: postgres:16
    container_name: dwh_postgres
    ports:
      - "5433:5432"
    environment:
      POSTGRES_USER: nyanu
      POSTGRES_PASSWORD: nyanu
      POSTGRES_DB: data_warehouse_gold
    volumes:
      - /home/nyanu/Documents/ETL_Projet/postgres_gold/data:/var/lib/postgresql/data
    restart: unless-stopped
    networks:
      etl_network:
        ipv4_address: 172.18.0.4
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U nyanu -d data_warehouse_gold"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s
```

---

## Annexe B — Scripts JavaScript n8n (Code nodes)

Les workflows n8n sont configurés via l'interface graphique. Les Code nodes
contiennent du JavaScript exécuté à chaque déclenchement. Voici les scripts
des nœuds clés.

### B.1 — Lecture d'un fichier source (WF-01 : data.csv)

Ce nœud lit le fichier CSV depuis le bind mount Docker et le convertit en binaire base64
pour l'envoi vers MinIO.

```javascript
// Nœud : "Lire data.csv (bind mount)"
// Workflow : WF-01 — Bronze CSV

const fs = require('fs');

const filePath = '/data_sources/data.csv';
const buf = fs.readFileSync(filePath);

return [{
  json: { fileName: 'data.csv', size: buf.length },
  binary: {
    data: {
      data: buf.toString('base64'),
      mimeType: 'text/csv',
      fileName: 'data.csv',
    }
  }
}];
```

### B.2 — CDC (Change Data Capture) par hash MD5

Ce nœud calcule un hash MD5 du fichier et le compare au hash précédemment stocké.
Si le hash a changé, les données sont retransférées vers MinIO. Sinon, le workflow
s'arrête sans upload.

```javascript
// Nœud : "CDC — Hash MD5 + Chemins MinIO"
// Utilisé dans WF-01 (CSV), WF-02 (JSON), WF-03 (PostgreSQL), WF-04 (Distances)

const crypto = require('crypto');
const fs     = require('fs');

// 1. Récupérer le binaire du nœud précédent
const item   = $input.first();
const buf    = Buffer.from(item.binary.data.data, 'base64');

// 2. Calculer le hash MD5 actuel
const currentHash = crypto.createHash('md5').update(buf).digest('hex');

// 3. Lire le hash précédemment enregistré
const checksumKey  = 'data_csv';
const checksumPath = `/staging/_metadata/checksums/${checksumKey}.json`;

function readChecksum(key) {
  try {
    return JSON.parse(fs.readFileSync(`/staging/_metadata/checksums/${key}.json`, 'utf8'));
  } catch(e) {
    return { hash: null };
  }
}
const { hash: storedHash } = readChecksum(checksumKey);

// 4. Comparer : hashChanged = true si les données ont changé
const hashChanged = currentHash !== storedHash;

// 5. Construire les chemins MinIO versionnés
const now     = new Date();
const YYYY    = now.getFullYear();
const MM      = String(now.getMonth() + 1).padStart(2, '0');
const DD      = String(now.getDate()).padStart(2, '0');
const HHmm    = String(now.getHours()).padStart(2, '0') + String(now.getMinutes()).padStart(2, '0');
const version = `${YYYY}${MM}${DD}_${HHmm}`;

const versionedKey = `raw/flat_files/data_csv/${YYYY}/${MM}/${DD}/${version}/data.csv`;
const latestKey    = `raw/flat_files/data_csv/latest/data.csv`;

return [{
  json: {
    hashChanged,
    currentHash,
    storedHash,
    versionedKey,
    latestKey,
    checksumKey,
    fileName: 'data.csv',
  },
  binary: item.binary
}];
```

### B.3 — Restauration du binaire entre deux uploads S3

En n8n 2.x, un nœud S3 Upload consomme le binaire et ne le transmet pas au nœud
suivant. Ce Code node le restaure depuis le nœud CDC avant le second upload.

```javascript
// Nœud : "Restaurer binaire CSV"
// Placé entre "MinIO — Upload Versionné" et "MinIO — Upload latest"

const cdcOut = $('CDC — Hash MD5 + Chemins MinIO').first();
const s3Out  = $input.first();

return [{
  json:   { ...cdcOut.json, ...s3Out.json },
  binary: cdcOut.binary
}];
```

### B.4 — Écriture staging + sauvegarde du checksum

Après l'upload MinIO réussi, ce nœud écrit le fichier en zone de staging
(accessible par Apache Hop) et met à jour le checksum CDC.

```javascript
// Nœud : "Écrire Staging + Sauver Checksum"

const fs   = require('fs');
const item = $input.first();
const buf  = Buffer.from(item.binary.data.data, 'base64');

// Écrire dans le staging partagé avec Apache Hop
fs.mkdirSync('/staging/flat_files', { recursive: true });
fs.writeFileSync('/staging/flat_files/data.csv', buf);

// Sauvegarder le checksum pour le prochain cycle CDC
fs.mkdirSync('/staging/_metadata/checksums', { recursive: true });
fs.writeFileSync('/staging/_metadata/checksums/data_csv.json',
  JSON.stringify({
    hash:      item.json.currentHash,
    updatedAt: new Date().toISOString(),
    fileName:  'data.csv',
    size:      buf.length,
  })
);

return [{ json: { status: 'ok', wrote: '/staging/flat_files/data.csv' } }];
```

### B.5 — Requête PostgreSQL Windows (WF-03)

Ce nœud se connecte directement à la base PostgreSQL Windows via VPN
et extrait les données en JSON pour l'upload vers MinIO.

```javascript
// Nœud : "Requête PG — clients"
// Workflow : WF-03 — Bronze PostgreSQL

const { Client } = require('pg');  // NODE_FUNCTION_ALLOW_EXTERNAL=pg requis

const client = new Client({
  host:                    '10.14.219.2',
  port:                    5433,
  database:                'database_extern_local',
  user:                    'postgres',
  password:                'postgres',
  connectionTimeoutMillis: 10000,
  statement_timeout:       30000,
});

await client.connect();
const res = await client.query('SELECT row_to_json(t) AS r FROM "clients" t');
await client.end();

const rows = res.rows.map(row => row.r);
return [{ json: { rows, count: rows.length } }];
```

### B.6 — Déclenchement manuel via webhook (WF-06)

Commande pour déclencher le pipeline complet sans attendre le cron :

```bash
curl -X POST http://localhost:5678/webhook/run-etl-pipeline \
  -H "Content-Type: application/json" \
  -d '{"source":"manual","triggered_by":"terminal"}'

# Réponse :
# {"message":"Workflow was started"}
```

---

## Annexe C — Micro-service ETL Runner (`etl_runner/app.py`)

Serveur HTTP Python qui reçoit les requêtes de n8n (WF-05) et déclenche
les pipelines Apache Hop via la commande `docker exec`.

```python
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

        log.info("Déclenchement Apache Hop — workflow: %s", HOP_WORKFLOW)
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
            if success:
                log.info("Hop terminé (rc=%d)", result.returncode)
            else:
                log.error("Hop en erreur (rc=%d)\n%s", result.returncode, result.stderr[-500:])

            self._json(200 if success else 500, {
                "status":      "success" if success else "error",
                "returncode":  result.returncode,
                "started_at":  started,
                "ended_at":    datetime.utcnow().isoformat(),
                "stdout_tail": result.stdout[-3000:],
                "stderr_tail": result.stderr[-500:],
            })
        except subprocess.TimeoutExpired:
            log.error("Timeout — Hop a dépassé 2h")
            self._json(504, {"status": "timeout", "message": "Hop > 2h"})
        except Exception as exc:
            log.exception("Erreur inattendue")
            self._json(500, {"status": "error", "message": str(exc)})


if __name__ == "__main__":
    port = int(os.getenv("PORT", 9999))
    log.info("ETL Runner démarré sur :%d", port)
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
```

---

## Annexe D — Script de démarrage Apache Hop (`hop_start.sh`)

Script Bash qui démarre Apache Hop Web et lance simultanément un serveur HTTP Java
compilé à la volée, permettant à n8n de déclencher les pipelines Hop via une API REST.

```bash
#!/bin/bash
# Wrapper autour de /tmp/run-web.sh
# Force HOP_PROJECT_NAME comme projet par défaut via sed

set -Euo pipefail

log() {
  echo "$(date '+%Y/%m/%d %H:%M:%S') - ${1}"
}

# ── Serveur HTTP Java pour déclencher hop-run depuis n8n (port 9999) ──
start_hop_api_server() {
  # Écrire le fichier Java inline et le compiler au démarrage
  cat > /tmp/HopApiServer.java << 'JAVA_EOF'
import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpExchange;
import java.net.InetSocketAddress;
import java.io.*;
import java.nio.charset.StandardCharsets;

public class HopApiServer {
  private static final int PORT = 9999;

  public static void main(String[] args) throws Exception {
    HttpServer server = HttpServer.create(new InetSocketAddress(PORT), 0);

    // Route POST /run-etl — déclenche hop-run.sh
    server.createContext("/run-etl", (HttpExchange ex) -> {
      if (!"POST".equalsIgnoreCase(ex.getRequestMethod())) {
        byte[] b = "{\"error\":\"POST required\"}".getBytes();
        ex.sendResponseHeaders(405, b.length);
        ex.getResponseBody().write(b);
        ex.getResponseBody().close();
        return;
      }
      System.out.println("[HopApiServer] POST /run-etl — lancement hop-run.sh");
      try {
        ProcessBuilder pb = new ProcessBuilder("/bin/bash", "-c",
          "/usr/local/tomcat/webapps/ROOT/hop-run.sh " +
          "--project=ETL_Projet --file=/project/workflows/main_etl.hwf " +
          "--runconfig=local 2>&1");
        pb.redirectErrorStream(true);
        pb.environment().put("HOP_PROJECT_NAME", "ETL_Projet");
        pb.environment().put("HOP_PROJECT_FOLDER", "/project");
        Process proc = pb.start();
        String out  = new String(proc.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
        int    code = proc.waitFor();
        // Nettoyer la sortie pour l'encapsuler en JSON
        String esc = out.replace("\\","\\\\").replace("\"","\\\"")
                        .replace("\n","\\n").replace("\r","");
        if (esc.length() > 2000) esc = esc.substring(esc.length() - 2000);
        String body = "{\"status\":\"" + (code == 0 ? "success" : "error") +
                      "\",\"exitCode\":" + code + ",\"output\":\"" + esc + "\"}";
        byte[] b = body.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json");
        ex.sendResponseHeaders(200, b.length);
        ex.getResponseBody().write(b);
        System.out.println("[HopApiServer] exitCode=" + code);
      } catch (Exception e) {
        byte[] b = ("{\"status\":\"error\",\"message\":\"" + e.getMessage() + "\"}").getBytes();
        ex.sendResponseHeaders(500, b.length);
        ex.getResponseBody().write(b);
      } finally { ex.getResponseBody().close(); }
    });

    // Route GET /health — vérification de disponibilité
    server.createContext("/health", (HttpExchange ex) -> {
      byte[] b = "{\"status\":\"ok\"}".getBytes();
      ex.getResponseHeaders().set("Content-Type", "application/json");
      ex.sendResponseHeaders(200, b.length);
      ex.getResponseBody().write(b);
      ex.getResponseBody().close();
    });

    server.setExecutor(null);
    server.start();
    System.out.println("[HopApiServer] Port 9999 prêt");
  }
}
JAVA_EOF

  cd /tmp && javac HopApiServer.java 2>/tmp/hop-api-compile.log && \
    java HopApiServer >> /tmp/hop-api-server.log 2>&1 &
  log "HopApiServer démarré sur port 9999 (PID=$!)"
}

start_hop_api_server

# Démarrer Hop Web en arrière-plan
/tmp/run-web.sh &
ORIG_PID=$!

# Patcher hop-config.json pour forcer le projet par défaut
(
  sleep 15
  CONFIG=/usr/local/tomcat/webapps/ROOT/config/hop-config.json
  PROJ="${HOP_PROJECT_NAME:-ETL_Projet}"
  if [ -f "${CONFIG}" ]; then
    sed -i "s/\"defaultProject\" : \"[^\"]*\"/\"defaultProject\" : \"${PROJ}\"/" "${CONFIG}"
    log "Projet par défaut patché → ${PROJ}"
  fi
) &

trap "kill -TERM ${ORIG_PID} 2>/dev/null" SIGTERM SIGINT SIGHUP
wait ${ORIG_PID}
```

---

## Annexe E — Workflow principal Apache Hop (`main_etl.hwf`)

Orchestre l'enchaînement complet Bronze → Silver → Gold puis nettoie les tables
Silver temporaires.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<workflow>
  <name>main_etl</name>
  <description>Pipeline ETL complet Bronze→Silver→Gold</description>

  <actions>
    <action>
      <name>Start</name>
      <type>SPECIAL</type>
    </action>

    <!-- COUCHE SILVER : nettoyage et normalisation -->
    <action>
      <name>ETL Silver</name>
      <description>Staging Bronze → silver.* (nettoyage et normalisation)</description>
      <type>WORKFLOW</type>
      <filename>${PROJECT_HOME}/workflows/main_etl_silver.hwf</filename>
      <run_configuration>local</run_configuration>
      <wait_until_finished>Y</wait_until_finished>
    </action>

    <!-- COUCHE GOLD : chargement Data Warehouse -->
    <action>
      <name>ETL Gold</name>
      <description>silver.* → PostgreSQL Gold DWH (dimensions et faits)</description>
      <type>WORKFLOW</type>
      <filename>${PROJECT_HOME}/workflows/main_etl_gold.hwf</filename>
      <run_configuration>local</run_configuration>
      <wait_until_finished>Y</wait_until_finished>
    </action>

    <!-- CLEANUP : purge des tables Silver temporaires -->
    <action>
      <name>Cleanup Silver</name>
      <description>Purge des tables silver.* après chargement Gold</description>
      <type>SQL</type>
      <connection>postgres_gold</connection>
      <sql>
        TRUNCATE TABLE silver.clients;
        TRUNCATE TABLE silver.articles;
        TRUNCATE TABLE silver.salesshipmentheader;
        TRUNCATE TABLE silver.salesshipmentline;
        TRUNCATE TABLE silver.distance_matrix;
        TRUNCATE TABLE silver.ecommerce_lines;
      </sql>
    </action>

    <action>
      <name>ETL Termine</name>
      <type>SUCCESS</type>
    </action>
  </actions>

  <hops>
    <hop><from>Start</from>      <to>ETL Silver</to>    <unconditional>Y</unconditional></hop>
    <hop><from>ETL Silver</from> <to>ETL Gold</to>      <evaluation>Y</evaluation></hop>
    <hop><from>ETL Gold</from>   <to>Cleanup Silver</to><evaluation>Y</evaluation></hop>
    <hop><from>Cleanup Silver</from><to>ETL Termine</to><evaluation>Y</evaluation></hop>
  </hops>
</workflow>
```

---

## Annexe F — Workflow couche Silver (`main_etl_silver.hwf`)

Orchestre les 6 pipelines Silver en séquence, chacun lisant depuis le staging Bronze
et chargeant dans le schéma `silver` de PostgreSQL.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<workflow>
  <name>main_etl_silver</name>
  <description>Orchestre la couche Silver : lit le staging Bronze, nettoie et charge dans silver.*</description>

  <actions>
    <action><name>Start</name><type>SPECIAL</type></action>

    <action>
      <name>01_silver_clients</name>
      <description>Charge les clients Bronze → silver.clients</description>
      <type>PIPELINE</type>
      <filename>${PROJECT_HOME}/pipelines/silver/01_silver_clients.hpl</filename>
      <run_configuration>local</run_configuration>
      <wait_until_finished>Y</wait_until_finished>
    </action>

    <action>
      <name>02_silver_articles</name>
      <description>Charge les articles Bronze → silver.articles</description>
      <type>PIPELINE</type>
      <filename>${PROJECT_HOME}/pipelines/silver/02_silver_articles.hpl</filename>
      <run_configuration>local</run_configuration>
      <wait_until_finished>Y</wait_until_finished>
    </action>

    <action>
      <name>03_silver_shipmentheader</name>
      <description>Charge les entêtes expéditions Bronze → silver.salesshipmentheader</description>
      <type>PIPELINE</type>
      <filename>${PROJECT_HOME}/pipelines/silver/03_silver_shipmentheader.hpl</filename>
      <run_configuration>local</run_configuration>
      <wait_until_finished>Y</wait_until_finished>
    </action>

    <action>
      <name>04_silver_shipmentlines</name>
      <description>Charge les lignes expéditions Bronze → silver.salesshipmentline</description>
      <type>PIPELINE</type>
      <filename>${PROJECT_HOME}/pipelines/silver/04_silver_shipmentlines.hpl</filename>
      <run_configuration>local</run_configuration>
      <wait_until_finished>Y</wait_until_finished>
    </action>

    <action>
      <name>05_silver_distances</name>
      <description>Charge les distances Google API → silver.distance_matrix</description>
      <type>PIPELINE</type>
      <filename>${PROJECT_HOME}/pipelines/silver/05_silver_distances.hpl</filename>
      <run_configuration>local</run_configuration>
      <wait_until_finished>Y</wait_until_finished>
    </action>

    <action>
      <name>06_silver_flat_files</name>
      <description>Charge le CSV e-commerce Bronze → silver.ecommerce_lines</description>
      <type>PIPELINE</type>
      <filename>${PROJECT_HOME}/pipelines/silver/06_silver_flat_files.hpl</filename>
      <run_configuration>local</run_configuration>
      <wait_until_finished>Y</wait_until_finished>
    </action>

    <action><name>Silver Termine</name><type>SUCCESS</type></action>
  </actions>

  <hops>
    <hop><from>Start</from>                <to>01_silver_clients</to>       <unconditional>Y</unconditional></hop>
    <hop><from>01_silver_clients</from>    <to>02_silver_articles</to>      <evaluation>Y</evaluation></hop>
    <hop><from>02_silver_articles</from>   <to>03_silver_shipmentheader</to><evaluation>Y</evaluation></hop>
    <hop><from>03_silver_shipmentheader</from><to>04_silver_shipmentlines</to><evaluation>Y</evaluation></hop>
    <hop><from>04_silver_shipmentlines</from><to>05_silver_distances</to>   <evaluation>Y</evaluation></hop>
    <hop><from>05_silver_distances</from>  <to>06_silver_flat_files</to>    <evaluation>Y</evaluation></hop>
    <hop><from>06_silver_flat_files</from> <to>Silver Termine</to>          <evaluation>Y</evaluation></hop>
  </hops>
</workflow>
```

---

## Annexe G — Pipeline Silver : nettoyage clients (`01_silver_clients.hpl`)

Exemple de pipeline Silver : lit les données clients depuis le fichier JSON Bronze
(staging), extrait les champs nécessaires et les charge dans `silver.clients`
(TRUNCATE + INSERT par lots de 100).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<pipeline>
  <info>
    <name>01_silver_clients</name>
    <description>Nettoie et charge les clients depuis staging Bronze vers silver.clients</description>
    <pipeline_type>Normal</pipeline_type>
    <created_date>2026/05/27 00:00:00.000</created_date>
  </info>

  <order>
    <hop><from>Read Bronze JSON</from><to>Load silver.clients</to><enabled>Y</enabled></hop>
  </order>

  <!-- ÉTAPE 1 : Lire les données Bronze depuis le staging -->
  <transform>
    <name>Read Bronze JSON</name>
    <type>JsonInput</type>
    <file>
      <name>/staging/database/clients.json</name>
      <file_required>Y</file_required>
    </file>
    <fields>
      <field>
        <name>customer_no</name>
        <path>$.data[*].customer_no</path>
        <type>String</type>
        <trim_type>both</trim_type>
      </field>
      <field>
        <name>name</name>
        <path>$.data[*].name</path>
        <type>String</type>
        <trim_type>both</trim_type>
      </field>
      <field>
        <name>customer_posting_group</name>
        <path>$.data[*].customer_posting_group</path>
        <type>String</type>
        <trim_type>both</trim_type>
      </field>
      <field>
        <name>country_region_code</name>
        <path>$.data[*].country_region_code</path>
        <type>String</type>
        <trim_type>both</trim_type>
      </field>
    </fields>
  </transform>

  <!-- ÉTAPE 2 : Charger dans le schéma Silver (TRUNCATE + INSERT) -->
  <transform>
    <name>Load silver.clients</name>
    <type>TableOutput</type>
    <connection>postgres_gold</connection>
    <schema>silver</schema>
    <table>clients</table>
    <commit>100</commit>
    <truncate>Y</truncate>
    <use_batch>Y</use_batch>
    <fields>
      <field><column_name>customer_no</column_name>            <stream_name>customer_no</stream_name></field>
      <field><column_name>name</column_name>                   <stream_name>name</stream_name></field>
      <field><column_name>customer_posting_group</column_name> <stream_name>customer_posting_group</stream_name></field>
      <field><column_name>country_region_code</column_name>    <stream_name>country_region_code</stream_name></field>
    </fields>
  </transform>
</pipeline>
```

---

## Annexe H — Pipeline Gold : dimension date (`01_dim_date.hpl`)

Exemple de pipeline Gold : génère la dimension calendrier complète (2010–2030)
directement depuis PostgreSQL via `generate_series`, puis effectue un UPSERT
dans `public.dim_date`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<pipeline>
  <info>
    <name>01_dim_date</name>
    <description>Génère et charge la dimension date (2010-2030) dans PostgreSQL Gold</description>
    <created_date>2026/05/25 00:00:00.000</created_date>
  </info>

  <order>
    <hop><from>Generate Date Series</from><to>Load dim_date</to><enabled>Y</enabled></hop>
  </order>

  <!-- ÉTAPE 1 : Générer la série de dates via PostgreSQL -->
  <transform>
    <name>Generate Date Series</name>
    <type>TableInput</type>
    <connection>postgres_gold</connection>
    <sql><![CDATA[
SELECT
    d::date AS date_id,
    EXTRACT(YEAR    FROM d)::integer   AS year,
    EXTRACT(QUARTER FROM d)::integer   AS quarter,
    EXTRACT(MONTH   FROM d)::integer   AS month,
    CASE EXTRACT(MONTH FROM d)
        WHEN 1  THEN 'Janvier'   WHEN 2  THEN 'Février'
        WHEN 3  THEN 'Mars'      WHEN 4  THEN 'Avril'
        WHEN 5  THEN 'Mai'       WHEN 6  THEN 'Juin'
        WHEN 7  THEN 'Juillet'   WHEN 8  THEN 'Août'
        WHEN 9  THEN 'Septembre' WHEN 10 THEN 'Octobre'
        WHEN 11 THEN 'Novembre'  WHEN 12 THEN 'Décembre'
    END                                AS month_name,
    EXTRACT(WEEK    FROM d)::integer   AS week,
    EXTRACT(DAY     FROM d)::integer   AS day_of_month,
    (EXTRACT(DOW    FROM d)::integer + 1) AS day_of_week,
    CASE EXTRACT(DOW FROM d)
        WHEN 0 THEN 'Dimanche' WHEN 1 THEN 'Lundi'
        WHEN 2 THEN 'Mardi'    WHEN 3 THEN 'Mercredi'
        WHEN 4 THEN 'Jeudi'    WHEN 5 THEN 'Vendredi'
        WHEN 6 THEN 'Samedi'
    END                                AS day_name,
    (EXTRACT(DOW FROM d) IN (0, 6))    AS is_weekend
FROM generate_series(
    '2010-01-01'::date,
    '2030-12-31'::date,
    '1 day'::interval
) AS d
ORDER BY d
    ]]></sql>
  </transform>

  <!-- ÉTAPE 2 : UPSERT dans dim_date (INSERT ou UPDATE si date_id existe déjà) -->
  <transform>
    <name>Load dim_date</name>
    <type>InsertUpdate</type>
    <connection>postgres_gold</connection>
    <lookup>
      <schema>public</schema>
      <table>dim_date</table>
      <!-- Clé de recherche : date_id -->
      <key>
        <name>date_id</name><field>date_id</field><condition>=</condition>
      </key>
      <!-- Colonnes mises à jour si la date existe déjà -->
      <value><name>year</name>         <update>Y</update></value>
      <value><name>quarter</name>      <update>Y</update></value>
      <value><name>month</name>        <update>Y</update></value>
      <value><name>month_name</name>   <update>Y</update></value>
      <value><name>week</name>         <update>Y</update></value>
      <value><name>day_of_month</name> <update>Y</update></value>
      <value><name>day_of_week</name>  <update>Y</update></value>
      <value><name>day_name</name>     <update>Y</update></value>
      <value><name>is_weekend</name>   <update>Y</update></value>
    </lookup>
  </transform>
</pipeline>
```

---

*Fin des annexes — Projet ETL Local | Nyanu K. | 2026-06-20*
