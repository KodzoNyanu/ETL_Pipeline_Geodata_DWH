# 🔌 Guide — Connectivité n8n (10.14.210.159) ↔ Windows (192.168.1.27)

## Problème
Les deux machines sont sur des sous-réseaux différents.  
n8n a besoin d'accéder aux :
- **Fichiers plats** : `data.csv`, `data.json` (sur Windows)
- **Base PostgreSQL** : `database_extern_local` (sur Windows)

---

## ✅ Solution retenue : ngrok HTTP (déjà en place)

Ton installation utilise déjà l'URL fixe :  
`https://swinger-sponge-defile.ngrok-free.dev`

### Ce que le serveur Windows doit exposer

| Route | Méthode | Contenu |
|---|---|---|
| `/data.csv` | GET | Retourne le fichier CSV (Content-Type: text/csv) |
| `/data.json` | GET | Retourne le fichier JSON (Content-Type: application/json) |
| `/query` | POST | Corps = nom de table → retourne les données JSON |

### Serveur HTTP minimal sur Windows (Python)

```cmd
REM Dans le dossier contenant data.csv, data.json + le script API
python -m pip install flask psycopg2-binary
python windows_api_server.py
```

**`windows_api_server.py`** (à créer sur Windows) :

```python
from flask import Flask, request, jsonify, send_file, abort
import psycopg2, json, os

app = Flask(__name__)
DB = {"host":"localhost","port":5432,"dbname":"TonNomBDD","user":"TonUser","password":"TonMdp"}
FILES_DIR = r"C:\chemin\vers\tes\fichiers"  # ← adapter

@app.route('/data.csv')
def csv():
    return send_file(os.path.join(FILES_DIR, 'data.csv'), mimetype='text/csv')

@app.route('/data.json')
def json_file():
    return send_file(os.path.join(FILES_DIR, 'data.json'), mimetype='application/json')

@app.route('/query', methods=['POST'])
def query():
    table = request.data.decode().strip()
    ALLOWED = {'clients','articles','salesshipmentheader','salesshipmentline'}
    if table not in ALLOWED:
        abort(400, f"Table '{table}' non autorisée")
    try:
        conn = psycopg2.connect(**DB)
        cur  = conn.cursor()
        cur.execute(f'SELECT row_to_json(t) FROM "{table}" t')
        rows = [row[0] for row in cur.fetchall()]
        conn.close()
        return jsonify(rows)
    except Exception as e:
        abort(500, str(e))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
```

### Exposer via ngrok (conserver l'URL fixe)

```cmd
REM Arrêter l'ancien ngrok si lancé
REM Relancer avec le bon port
ngrok http 8080 --domain=swinger-sponge-defile.ngrok-free.dev
```

> **Important :** Tu gardes toujours la même URL dans n8n (`WINDOWS_NGROK_URL`).

---

## 🏆 Alternative recommandée : Tailscale (plus stable)

Tailscale crée un VPN P2P gratuit. Chaque machine obtient une IP `100.x.x.x`.

### Installation

**Sur Windows (192.168.1.27) :**
```
1. Télécharger https://tailscale.com/download/windows
2. Installer et se connecter (créer un compte gratuit)
3. Note l'IP Tailscale de Windows (ex: 100.64.0.2)
```

**Sur Linux (10.14.210.159) :**
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# Note l'IP Tailscale du Linux (ex: 100.64.0.3)
```

### Mettre à jour n8n après Tailscale

Avec Tailscale, plus besoin de ngrok ! Mettre à jour la variable n8n :

```
WINDOWS_NGROK_URL = http://100.64.0.2:8080
```

Et lancer le serveur Flask sur Windows sans ngrok :
```cmd
python windows_api_server.py  # expose sur 0.0.0.0:8080
```

---

## 🔧 Mettre à jour l'URL ngrok dans n8n

Quand l'URL ngrok change (redémarrage du tunnel) :

```bash
# Sur 10.14.210.159
docker exec ingestion_n8n node /tmp/update_ngrok.js NOUVELLE_URL
```

Ou dans l'interface n8n : **Settings → Variables → WINDOWS_NGROK_URL**

---

## Vérification de connectivité

```bash
# Depuis la machine Linux (10.14.210.159), tester l'accès au serveur Windows
curl -s "https://swinger-sponge-defile.ngrok-free.dev/data.csv" | head -1
# Doit retourner la première ligne du CSV

curl -s -X POST "https://swinger-sponge-defile.ngrok-free.dev/query" \
     -d "clients" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{len(d)} lignes clients')"
```
