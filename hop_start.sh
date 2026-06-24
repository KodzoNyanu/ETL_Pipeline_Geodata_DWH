#!/bin/bash
# Wrapper autour de /tmp/run-web.sh
# Force HOP_PROJECT_NAME comme projet par défaut via sed (pas hop-conf.sh)
# car hop-conf.sh --default-project réinitialise et efface les projets enregistrés

set -Euo pipefail

log() {
  echo "$(date '+%Y/%m/%d %H:%M:%S') - ${1}"
}

# ── Mini serveur HTTP Java pour déclencher hop-run depuis n8n (port 9999) ──
# Copier et compiler HopApiServer.java au démarrage
start_hop_api_server() {
  local SRC_CLASS="/usr/local/tomcat/webapps/ROOT/HopApiServer.class"
  local SRC_JAVA="/usr/local/tomcat/webapps/ROOT/HopApiServer.java"

  # Écrire le fichier Java inline
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
    server.createContext("/run-etl", (HttpExchange ex) -> {
      if (!"POST".equalsIgnoreCase(ex.getRequestMethod())) {
        byte[] b="{\"error\":\"POST required\"}".getBytes(); ex.sendResponseHeaders(405,b.length); ex.getResponseBody().write(b); ex.getResponseBody().close(); return;
      }
      System.out.println("[HopApiServer] POST /run-etl — lancement hop-run.sh");
      try {
        ProcessBuilder pb = new ProcessBuilder("/bin/bash","-c",
          "/usr/local/tomcat/webapps/ROOT/hop-run.sh --project=ETL_Projet --file=/project/workflows/main_etl.hwf --runconfig=local 2>&1");
        pb.redirectErrorStream(true);
        pb.environment().put("HOP_PROJECT_NAME","ETL_Projet");
        pb.environment().put("HOP_PROJECT_FOLDER","/project");
        Process proc=pb.start();
        String out=new String(proc.getInputStream().readAllBytes(),StandardCharsets.UTF_8);
        int code=proc.waitFor();
        String esc=out.replace("\\","\\\\").replace("\"","\\\"").replace("\n","\\n").replace("\r","");
        if(esc.length()>2000) esc=esc.substring(esc.length()-2000);
        String body="{\"status\":\""+(code==0?"success":"error")+"\",\"exitCode\":"+code+",\"output\":\""+esc+"\"}";
        byte[] b=body.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type","application/json");
        ex.sendResponseHeaders(200,b.length); ex.getResponseBody().write(b);
        System.out.println("[HopApiServer] exitCode="+code);
      } catch(Exception e) {
        byte[] b=("{\"status\":\"error\",\"message\":\""+e.getMessage()+"\"}").getBytes();
        ex.sendResponseHeaders(500,b.length); ex.getResponseBody().write(b);
      } finally { ex.getResponseBody().close(); }
    });
    server.createContext("/health",(HttpExchange ex)->{
      byte[] b="{\"status\":\"ok\"}".getBytes();
      ex.getResponseHeaders().set("Content-Type","application/json");
      ex.sendResponseHeaders(200,b.length); ex.getResponseBody().write(b); ex.getResponseBody().close();
    });
    server.setExecutor(null); server.start();
    System.out.println("[HopApiServer] ✅ Port 9999 prêt");
  }
}
JAVA_EOF

  cd /tmp && javac HopApiServer.java 2>/tmp/hop-api-compile.log && \
    java -DHOP_WORKFLOW=/project/workflows/main_etl.hwf HopApiServer >> /tmp/hop-api-server.log 2>&1 &
  log "HopApiServer démarré sur port 9999 (PID=$!)"
}
start_hop_api_server

# Démarrer le script original en arrière-plan
/tmp/run-web.sh &
ORIG_PID=$!

# Après que run-web.sh ait terminé la création du projet,
# patcher hop-config.json directement avec sed
(
  sleep 15
  CONFIG=/usr/local/tomcat/webapps/ROOT/config/hop-config.json
  PROJ="${HOP_PROJECT_NAME:-ETL_Projet}"

  if [ -f "${CONFIG}" ]; then
    sed -i "s/\"defaultProject\" : \"[^\"]*\"/\"defaultProject\" : \"${PROJ}\"/" "${CONFIG}"
    log "Projet par défaut patché → ${PROJ}"
  else
    log "WARN: hop-config.json introuvable, skip patch"
  fi
) &

# Transmettre SIGTERM/SIGINT au script original (arrêt propre de Tomcat)
trap "kill -TERM ${ORIG_PID} 2>/dev/null" SIGTERM SIGINT SIGHUP

wait ${ORIG_PID}
