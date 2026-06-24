from flask import Flask, request, jsonify, send_file, abort
import psycopg2, os

app = Flask(__name__)

# ── Configuration ────────────────────────────────────────────────
FILES_DIR = r"D:\Projet de SI"          # dossier contenant data.csv et data.json
DB = {
    "host"    : "localhost",
    "port"    : 5432,
    "dbname"  : "database_extern_local",
    "user"    : "postgres",
    "password": ""                       # ← compléter si mot de passe défini
}
PORT = 8999
# ─────────────────────────────────────────────────────────────────

ALLOWED_TABLES = {'clients', 'articles', 'salesshipmentheader', 'salesshipmentline'}

@app.route('/data.csv')
def csv_file():
    path = os.path.join(FILES_DIR, 'data.csv')
    if not os.path.exists(path):
        abort(404, f"Fichier introuvable : {path}")
    return send_file(path, mimetype='text/csv')

@app.route('/data.json')
def json_file():
    path = os.path.join(FILES_DIR, 'data.json')
    if not os.path.exists(path):
        abort(404, f"Fichier introuvable : {path}")
    return send_file(path, mimetype='application/json')

@app.route('/query', methods=['POST'])
def query():
    table = request.data.decode().strip()
    if table not in ALLOWED_TABLES:
        abort(400, f"Table '{table}' non autorisee")
    try:
        conn = psycopg2.connect(**DB)
        cur  = conn.cursor()
        cur.execute(f'SELECT row_to_json(t) FROM "{table}" t')
        rows = [row[0] for row in cur.fetchall()]
        conn.close()
        return jsonify(rows)
    except Exception as e:
        abort(500, str(e))

@app.route('/health')
def health():
    return jsonify({"status": "ok"})

if __name__ == '__main__':
    print(f"[API Windows] Démarrage sur port {PORT}")
    print(f"[API Windows] Fichiers servis depuis : {FILES_DIR}")
    app.run(host='0.0.0.0', port=PORT)
