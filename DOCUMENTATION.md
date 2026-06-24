# Documentation technique — Projet ETL Local
**Version finale** | Mise à jour : 2026-05-26

---

## Table des matières

1. [Vue d'ensemble](#1-vue-densemble)
2. [Architecture infrastructure](#2-architecture-infrastructure)
3. [Sources de données](#3-sources-de-données)
4. [Pipeline n8n — Couche Bronze](#4-pipeline-n8n--couche-bronze)
5. [Patterns techniques communs](#5-patterns-techniques-communs)
6. [Configuration n8n](#6-configuration-n8n)
7. [Couche Silver / Gold — Apache Hop](#7-couche-silver--gold--apache-hop)
8. [Opérations courantes](#8-opérations-courantes)
9. [Journal des corrections](#9-journal-des-corrections)
10. [Référence des chemins](#10-référence-des-chemins)

---

## 1. Vue d'ensemble

Ce projet implémente un pipeline ETL complet fonctionnant **100 % localement** sur Linux (Ubuntu), sans dépendance à un service cloud ou à un tunnel externe (ngrok abandonné).

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SOURCES (Windows 10.14.219.2)                │
│  data.csv (20 MB)  │  data.json (90 MB)  │  PostgreSQL :5433        │
└────────┬───────────────────┬────────────────────┬────────────────────┘
         │                   │                    │
         │ bind mount        │ bind mount         │ VPN (pg@8.17)
         │ /data_sources/    │ /data_sources/     │ 10.14.219.2:5433
         ▼                   ▼                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    n8n (ingestion_n8n) :5678                        │
│  WF-01 CSV        WF-02 JSON        WF-03 PG        WF-04 Distances │
│  06h00            06h05             toutes 30min    08h00           │
│        └──────────────┴────────────────┴──────────────┘             │
│                          WF-05 Orchestrateur (07h00)                │
│                          WF-06 Webhook (déclenchement manuel)       │
└────────┬───────────────────┬────────────────────┬────────────────────┘
         │ CDC MD5           │ CDC MD5             │ CDC MD5
         ▼                   ▼                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│              MinIO datalake_minio :9000/:9001                       │
│  bucket: bronze                                                     │
│  raw/flat_files/data_csv/YYYY/MM/DD/YYYYMMdd_HHmm/data.csv        │
│  raw/flat_files/data_json/...                                      │
│  raw/database/{table}/...                                          │
└────────┬────────────────────────────────────────────────────────────┘
         │ /staging (volume partagé)
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│              Apache Hop (transform_hop) :8080                       │
│  Transformations Silver → Gold                                      │
└────────┬────────────────────────────────────────────────────────────┘
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│       PostgreSQL Gold (dwh_postgres) :5433 (hôte) / :5432 (docker) │
│  database: data_warehouse_gold  user: nyanu                         │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Architecture infrastructure

### 2.1 Docker Compose

Fichier : `docker-compose.yml`

| Service | Container | IP fixe | Ports exposés | Rôle |
|---------|-----------|---------|---------------|------|
| minio | datalake_minio | 172.18.0.3 | 9000, 9001 | Data Lake Bronze (stockage S3) |
| n8n | ingestion_n8n | 172.18.0.5 | 5678 | Orchestrateur ingestion + CDC |
| apache-hop | transform_hop | 172.18.0.2 | 8080 | Transformations Silver/Gold |
| postgres_gold | dwh_postgres | 172.18.0.4 | 5433→5432 | Data Warehouse cible |

Réseau Docker : `etl_network` — bridge, sous-réseau `172.18.0.0/16`

### 2.2 Variables d'environnement critiques n8n

```yaml
environment:
  - N8N_ENCRYPTION_KEY=nyanu_secret_key_99
  - WEBHOOK_URL=http://localhost:5678/
  - GENERIC_TIMEZONE=Europe/Paris
  - TZ=Europe/Paris
  # ⚠️ REQUIS pour les Code nodes utilisant fs, crypto, pg
  - NODE_FUNCTION_ALLOW_BUILTIN=fs,path,crypto,os,http,https,net
  - NODE_FUNCTION_ALLOW_EXTERNAL=pg
```

> **Note** : Sans `NODE_FUNCTION_ALLOW_BUILTIN` et `NODE_FUNCTION_ALLOW_EXTERNAL=pg`,
> tous les Code nodes utilisant `require('fs')`, `require('crypto')` ou `require('pg')`
> échouent avec "Module is disallowed".

### 2.3 Volumes montés

| Volume hôte | Chemin conteneur | Usage |
|-------------|-----------------|-------|
| `./n8n_data` | `/home/node/.n8n` | Base SQLite n8n + credentials |
| `./data_sources` | `/data_sources` | Fichiers plats sources (CSV, JSON) |
| `./staging` | `/staging` | Zone intermédiaire n8n → Apache Hop |
| `./minio/data` | `/data` | Données MinIO persistantes |
| `./apache_hop_data` | `/project` | Pipelines Apache Hop |
| `./postgres_gold/data` | `/var/lib/postgresql/data` | Données DWH Gold |

### 2.4 Connexion PostgreSQL Windows (source externe)

Le PostgreSQL source (données métier) tourne sur Windows et est accessible via VPN :

| Paramètre | Valeur |
|-----------|--------|
| Host | `10.14.219.2` |
| Port | `5433` |
| Base | `database_extern_local` |
| User | `postgres` |
| Password | `postgres` |
| Accès depuis n8n | Via VPN (interface Linux `ens34`) |

> **Prérequis réseau Windows** : La règle de pare-feu entrante autorisant TCP 5433 doit
> être active sur la machine Windows. Commande PowerShell pour la créer :
> ```powershell
> New-NetFirewallRule -DisplayName "PostgreSQL ETL 5433" -Direction Inbound `
>   -Protocol TCP -LocalPort 5433 -Action Allow -Profile Any
> ```

---

## 3. Sources de données

### 3.1 Fichiers plats (bind mount)

Les fichiers sources sont copiés dans `/home/nyanu/Documents/ETL_Projet/data_sources/`
sur le serveur Linux. Ce répertoire est monté en lecture dans le conteneur n8n sous
`/data_sources/`.

| Fichier | Taille typique | Contenu |
|---------|---------------|---------|
| `data.csv` | ~20 MB | Données commerciales export ERP |
| `data.json` | ~90 MB | Données JSON enrichies |

**Mise à jour quotidienne** : copier les nouveaux fichiers dans `data_sources/` avant 06h00
(déclenchement WF-01 à 06h00, WF-02 à 06h05).

```bash
# Exemple de copie depuis Windows via SCP (si SSH disponible sur Windows)
scp "D:\Projet de SI\data.csv"  nyanu@10.14.210.159:/home/nyanu/Documents/ETL_Projet/data_sources/
scp "D:\Projet de SI\data.json" nyanu@10.14.210.159:/home/nyanu/Documents/ETL_Projet/data_sources/
```

### 3.2 Tables PostgreSQL Windows

4 tables extraites via connexion directe `pg@8.17.0` :

| Table | Description |
|-------|-------------|
| `clients` | Référentiel clients |
| `articles` | Catalogue articles |
| `salesshipmentheader` | En-têtes d'expéditions |
| `salesshipmentline` | Lignes d'expéditions |

### 3.3 API Google Distance Matrix (WF-04)

WF-04 lit les expéditions depuis `/staging/database/salesshipmentheader.json`,
extrait les paires origine/destination, et interroge l'API Google Distance Matrix.
La clé API Google doit être configurée dans le nœud HTTP Request de WF-04.

---

## 4. Pipeline n8n — Couche Bronze

### WF-01 — data.csv → MinIO (Bronze)

**ID** : `wf01-csv-cdc-v2` | **Déclenchement** : cron `06h00` quotidien + appel sous-workflow

**Flux** :
```
Schedule 06h00 ─┐
                ├─→ Lire data.csv (bind mount) ─→ CDC Hash MD5 ─→ Données modifiées ?
Déclencheur      │                                                     │YES        │NO
sous-workflow ──┘                                                      │           │
                                                                       ▼           ▼
                                           MinIO Versionné ─→ Restaurer binaire ─→ MinIO latest
                                                                       │
                                                                       ▼
                                                          Écrire Staging + Sauver Checksum
                                                          → /staging/flat_files/data.csv
```

**Nœuds clés** :

| Nœud | Type | Rôle |
|------|------|------|
| Lire data.csv (bind mount) | Code | `fs.readFileSync('/data_sources/data.csv')` → binaire base64 |
| CDC — Hash MD5 + Chemins MinIO | Code | MD5 du fichier, compare avec `/staging/_metadata/checksums/data_csv.json` |
| Données CSV modifiées ? | IF | `hashChanged === true` → branche upload |
| MinIO — Upload Versionné | S3 | Clé : `raw/flat_files/data_csv/YYYY/MM/DD/YYYYMMdd_HHmm/data.csv` |
| Restaurer binaire CSV | Code | Récupère `$('CDC — Hash MD5 + Chemins MinIO').first().binary` |
| MinIO — Upload latest | S3 | Clé : `raw/flat_files/data_csv/latest/data.csv` |
| Écrire Staging + Sauver Checksum | Code | Écrit `/staging/flat_files/data.csv` + met à jour le checksum |
| Déclencheur sous-workflow | executeWorkflowTrigger | Permet l'appel depuis WF-05 |

---

### WF-02 — data.json → MinIO (Bronze)

**ID** : `wf02-json-cdc-v2` | **Déclenchement** : cron `06h05` + appel sous-workflow

Même architecture que WF-01, adapté pour JSON.
Staging : `/staging/flat_files/data.json`
Chemin MinIO : `raw/flat_files/data_json/...`

---

### WF-03 — PostgreSQL Windows → MinIO (Bronze)

**ID** : `wf03-pg-cdc-v2` | **Déclenchement** : `toutes les 30 min` + appel sous-workflow

**Flux par table** (répété × 4) :
```
Requête PG — {table}
  → pg.Client({ host:'10.14.219.2', port:5433, database:'database_extern_local',
                user:'postgres', password:'postgres' })
  → return [{ json: { rows, count } }]
CDC Hash — {table}
  → JSON.stringify({ data: rows }), MD5, compare checksum
{table} modifié ?
  → MinIO Versionné — {table}
  → Restaurer binaire — {table}    ← récupère binary depuis CDC
  → MinIO latest — {table}
  → Stage+Checksum — {table}
    → /staging/database/{table}.json
```

**Tables traitées séquentiellement** :
`clients` → `articles` → `salesshipmentheader` → `salesshipmentline`

**Chemins MinIO** : `raw/database/{table}/YYYY/MM/DD/YYYYMMdd_HHmm/{table}.json`

**Pattern pg dans Code node** :
```javascript
const { Client } = require('pg');  // NODE_FUNCTION_ALLOW_EXTERNAL=pg requis
const client = new Client({
  host: '10.14.219.2', port: 5433,
  database: 'database_extern_local',
  user: 'postgres', password: 'postgres',
  connectionTimeoutMillis: 10000,
  statement_timeout: 30000
});
await client.connect();
const res = await client.query('SELECT row_to_json(t) AS r FROM "clients" t');
await client.end();
const rows = res.rows.map(row => row.r);
return [{ json: { rows, count: rows.length } }];
```

---

### WF-04 — Distance Matrix → MinIO (Bronze)

**ID** : `wf04-distances-cdc-v2` | **Déclenchement** : cron `08h00` + appel sous-workflow

**Flux** :
```
Lire salesshipmentheader (staging) [/staging/database/salesshipmentheader.json]
  → Référentiel adresses magasins [Code - enrichissement statique]
  → Dédupliquer paires O/D [removeDuplicates, fieldsToCompare: "origin,destination"]
  → Split — 1 paire à la fois [splitInBatches, batchSize: 1]
  → Google Distance Matrix API [HTTP Request]
  → Parser réponse Google [Code]
  → Agréger tous les résultats [Aggregate]
  → CDC — Hash distances
  → Distances modifiées ?
  → MinIO Versionné + latest + Stage+Checksum
```

**Staging** : `/staging/enrichment/enrichment_distance_matrix.json`
**Chemin MinIO** : `raw/enrichment/distances/...`

---

### WF-05 — Orchestrateur Pipeline Complet

**ID** : `wf05-orchestrateur-v1` | **Déclenchement** : cron `07h00` quotidien + appel sous-workflow (WF-06)

**Flux** :
```
Déclencheur 07h00 quotidien ─┐
                              ├─→ Vérifier fichiers sources [Code]
Déclencheur sous-workflow ───┘         /data_sources/data.csv ✓ ?
                                       /data_sources/data.json ✓ ?
                                              │YES                    │NO
                                              ▼                       ▼
                                   Exécuter WF-01 (CSV)      Fichiers manquants — Alerter
                                       ↓
                                   Exécuter WF-02 (JSON)
                                       ↓
                                   Exécuter WF-03 (PG)
                                       ↓
                                   Exécuter WF-04 (Distances)
                                       ↓
                                   Vérifier résultats
                                       ↓
                                   Tous OK ? ──[NON]──→ Erreur — Alerter
                                       │OUI
                                       ▼
                               Déclencher Apache Hop (ETL Gold)
                               POST http://172.18.0.6:9999/run-etl
                                       ↓
                                   Succès complet ✅
```

**Garde-fou** : Avant d'exécuter les sous-workflows, vérifie la présence de
`/data_sources/data.csv` et `/data_sources/data.json`. Si l'un manque, interrompt
le pipeline et logue l'erreur.

---

### WF-06 — Webhook Déclencheur Manuel

**ID** : `v5PpBenPvYrUtWv2` | **Déclenchement** : webhook `POST /webhook/run-etl-pipeline`

Workflow minimaliste : reçoit le webhook → lance WF-05 en mode asynchrone (`waitForSubWorkflow: false`) → répond immédiatement `{"message":"Workflow was started"}`.

**Utilisation** :
```bash
curl -X POST http://localhost:5678/webhook/run-etl-pipeline \
  -H "Content-Type: application/json" \
  -d '{"source":"manual"}'
```

---

## 5. Patterns techniques communs

### 5.1 CDC (Change Data Capture) par hash MD5

Chaque workflow implémente une détection de changements avant tout upload :

```javascript
// 1. Calcul du hash actuel
const currentHash = crypto.createHash('md5').update(buf).digest('hex');

// 2. Lecture du hash précédent (depuis /staging/_metadata/checksums/{key}.json)
function readChecksum(key) {
  try { return JSON.parse(fs.readFileSync(`/staging/_metadata/checksums/${key}.json`)); }
  catch(e) { return { hash: null }; }
}
const { hash: storedHash } = readChecksum('data_csv');

// 3. Décision : hashChanged = currentHash !== storedHash
// 4. Mise à jour du checksum après upload réussi
function saveChecksum(key, hash, meta) {
  fs.mkdirSync('/staging/_metadata/checksums', { recursive: true });
  fs.writeFileSync(`/staging/_metadata/checksums/${key}.json`,
    JSON.stringify({ hash, updatedAt: new Date().toISOString(), ...meta }));
}
```

**Checksums stockés** : `/staging/_metadata/checksums/`

| Fichier checksum | Workflow |
|-----------------|---------|
| `data_csv.json` | WF-01 |
| `data_json.json` | WF-02 |
| `clients.json` | WF-03 |
| `articles.json` | WF-03 |
| `salesshipmentheader.json` | WF-03 |
| `salesshipmentline.json` | WF-03 |
| `distances.json` | WF-04 |

### 5.2 Versionnage MinIO

Chaque upload crée deux clés S3 :

```
raw/{source}/{YYYY}/{MM}/{DD}/{YYYYMMdd_HHmm}/{filename}   ← version archivée
raw/{source}/latest/{filename}                              ← version courante
```

Exemple pour data.csv du 26/05/2026 à 00h31 :
```
raw/flat_files/data_csv/2026/05/26/20260526_0031/data.csv
raw/flat_files/data_csv/latest/data.csv
```

### 5.3 Passage du binaire entre nœuds S3

> **Problème n8n 2.x** : Les nœuds S3 (upload) suppriment le binaire de leur sortie.
> Le nœud suivant ne peut donc pas accéder au binaire original.

**Solution** : Nœuds "Restaurer binaire" intercalés entre les deux uploads S3 :

```javascript
// Placé entre "MinIO — Upload Versionné" et "MinIO — Upload latest"
const cdcOut = $('CDC — Hash MD5 + Chemins MinIO').first();
const s3Out  = $input.first();
return [{ json: { ...cdcOut.json, ...s3Out.json }, binary: cdcOut.binary }];
```

### 5.4 Nœud executeWorkflowTrigger

Pour qu'un workflow puisse être appelé en **sous-workflow** via le nœud
`executeWorkflow`, il **doit** contenir un nœud `executeWorkflowTrigger`.
Sans ce nœud, n8n 2.x retourne : `SubworkflowOperationError: Missing node to start execution`.

Ce nœud a été ajouté à WF-01, WF-02, WF-03, WF-04 et WF-05.
Il se connecte directement au premier nœud de traitement (contourne le schedule trigger).

### 5.5 Format de retour des Code nodes

En n8n 2.x, la propriété `json` d'un item **doit être un objet**, jamais un tableau :

```javascript
// ❌ INCORRECT — json est un tableau
return [{ json: rows }];

// ✅ CORRECT — json est un objet wrappant le tableau
return [{ json: { rows, count: rows.length } }];

// ✅ CORRECT — une ligne = un item
return rows.map(row => ({ json: row }));
```

---

## 6. Configuration n8n

### 6.1 API Key

```
Clé     : n8n_api_39cf9ddc772145ee828f396e51fdeabe
Header  : X-N8N-API-KEY: <clé>
Scopes  : workflow:list, workflow:read, workflow:update, workflow:activate,
          execution:list, execution:read, etc.
```

### 6.2 Credentials MinIO (S3)

```
Credential ID   : Iqpe5A6QfeoXeIZR
Nom             : MinIO S3 (path-style)
Endpoint        : http://172.18.0.3:9000
Access Key      : nyanu
Secret Key      : nyanu1234
Region          : us-east-1
Path-style      : true (obligatoire pour MinIO)
Bucket          : bronze
```

### 6.3 Base de données n8n

Type : SQLite — chemin dans le conteneur : `/home/node/.n8n/database.sqlite`
Sur l'hôte : `./n8n_data/database.sqlite`

**Tables importantes** :

| Table | Contenu |
|-------|---------|
| `workflow_entity` | Définitions des workflows (nodes, connections) |
| `workflow_history` | Historique des versions (lié via `activeVersionId`) |
| `execution_entity` | Journal des exécutions (status, startedAt, stoppedAt) |
| `execution_data` | Données détaillées d'exécution (format compressé) |
| `webhook_entity` | Webhooks enregistrés |
| `shared_workflow` | Association workflow ↔ projet/utilisateur |
| `user_api_keys` | Clés API avec scopes |
| `variables` | Variables globales n8n |

### 6.4 Workflows en base — IDs et statuts

| Workflow | ID en base | Statut |
|---------|-----------|--------|
| 01 - Bronze CSV | `wf01-csv-cdc-v2` | ✅ actif |
| 02 - Bronze JSON | `wf02-json-cdc-v2` | ✅ actif |
| 03 - Bronze PG | `wf03-pg-cdc-v2` | ✅ actif |
| 04 - Bronze Distances | `wf04-distances-cdc-v2` | ✅ actif |
| 05 - Orchestrateur | `wf05-orchestrateur-v1` | ✅ actif |
| 06 - Webhook Trigger | `v5PpBenPvYrUtWv2` | ✅ actif |

---

## 7. Couche Silver / Gold — Apache Hop

Apache Hop est déclenché en fin de pipeline par WF-05 (appel HTTP POST sur l'ETL Runner) :

```
POST http://172.18.0.6:9999/run-etl
```

L'ETL Runner (`etl_runner` / `172.18.0.6`) est un conteneur Python/Flask qui lance
`hop-run` dans le conteneur Apache Hop via le socket Docker.

**Paramètres Apache Hop** :
```
Container   : transform_hop
Projet      : etl_projet
Workflow    : /project/workflows/main_etl_gold.hwf
Config      : local
```

**Staging partagé** : le volume `/staging` est monté à la fois dans `ingestion_n8n`
et `transform_hop`, permettant à Apache Hop de lire les fichiers produits par n8n
sans transfert réseau.

**Schéma Gold** : défini dans `schema_gold.sql`, appliqué sur `dwh_postgres`
(base `data_warehouse_gold`, user `nyanu`).

---

## 8. Opérations courantes

### 8.1 Démarrer / arrêter l'infrastructure

```bash
# Démarrer tout
cd /home/nyanu/Documents/ETL_Projet
docker compose up -d

# Arrêter tout
docker compose down

# Redémarrer uniquement n8n
docker compose up -d n8n

# Voir les logs n8n en temps réel
docker logs -f ingestion_n8n
```

### 8.2 Déclencher le pipeline manuellement

```bash
# Depuis le terminal Linux (n'importe quel répertoire)
curl -X POST http://localhost:5678/webhook/run-etl-pipeline \
  -H "Content-Type: application/json" \
  -d '{"source":"manual","triggered_by":"terminal"}'

# Réponse attendue :
# {"message":"Workflow was started"}
```

### 8.3 Vérifier les logs d'exécution

```bash
# 10 dernières exécutions (toutes sources)
docker exec ingestion_n8n node -e "
var s=require('/usr/local/lib/node_modules/n8n/node_modules/.pnpm/sqlite3@5.1.7/node_modules/sqlite3/lib/sqlite3');
var db=new s.Database('/home/node/.n8n/database.sqlite');
db.all('SELECT id, workflowId, status, startedAt, stoppedAt FROM execution_entity ORDER BY startedAt DESC LIMIT 10', function(e,rows){
  rows.forEach(function(r){
    var dur=r.stoppedAt?Math.round((new Date(r.stoppedAt)-new Date(r.startedAt))/1000)+'s':'running';
    process.stdout.write(r.id+'|'+r.workflowId.substr(0,22).padEnd(23)+'|'+r.status.padEnd(9)+'|'+dur+'\n');
  }); db.close();
});"

# Dernière exécution de WF-05 uniquement
docker exec ingestion_n8n node -e "
var s=require('/usr/local/lib/node_modules/n8n/node_modules/.pnpm/sqlite3@5.1.7/node_modules/sqlite3/lib/sqlite3');
var db=new s.Database('/home/node/.n8n/database.sqlite');
db.get('SELECT id, status, startedAt, stoppedAt FROM execution_entity WHERE workflowId=\"wf05-orchestrateur-v1\" ORDER BY startedAt DESC LIMIT 1', function(e,r){
  if(r) process.stdout.write('WF-05 | '+r.status+' | start:'+r.startedAt+' | stop:'+r.stoppedAt+'\n');
  db.close();
});"
```

### 8.4 Vérifier les checksums CDC (données fraîches ?)

```bash
cat /home/nyanu/Documents/ETL_Projet/staging/_metadata/checksums/data_csv.json
cat /home/nyanu/Documents/ETL_Projet/staging/_metadata/checksums/clients.json
ls -la /home/nyanu/Documents/ETL_Projet/staging/_metadata/checksums/
```

### 8.5 Vérifier les fichiers stagés

```bash
ls -lh /home/nyanu/Documents/ETL_Projet/staging/flat_files/
ls -lh /home/nyanu/Documents/ETL_Projet/staging/database/
ls -lh /home/nyanu/Documents/ETL_Projet/staging/enrichment/
```

### 8.6 Accéder à la console MinIO

```
URL      : http://localhost:9001
User     : nyanu
Password : nyanu1234
Bucket   : bronze
```

### 8.7 Accéder à l'interface n8n

```
URL      : http://localhost:5678
Email    : nyanuks@s2.rpn.ch
```

### 8.8 Mettre à jour les fichiers sources (manuel)

```bash
# Copier data.csv et data.json dans data_sources/
cp /chemin/vers/data.csv  /home/nyanu/Documents/ETL_Projet/data_sources/
cp /chemin/vers/data.json /home/nyanu/Documents/ETL_Projet/data_sources/

# Puis déclencher le pipeline
curl -X POST http://localhost:5678/webhook/run-etl-pipeline \
  -H "Content-Type: application/json" -d '{}'
```

---

## 9. Journal des corrections

Corrections majeures appliquées pour migrer l'architecture et la faire fonctionner
sous n8n 2.21.7 en mode local.

### 9.1 Migration ngrok → bind mount + VPN

**Avant** : WF-01/02 récupéraient `data.csv`/`data.json` via HTTP Request vers
une URL ngrok (`https://swinger-sponge-defile.ngrok-free.dev/data.csv`).
WF-03 interrogeait PostgreSQL via `POST /query` sur ce même serveur ngrok.

**Après** :
- WF-01/02 : `fs.readFileSync('/data_sources/data.csv')` via bind mount Docker
- WF-03 : `require('pg')` + connexion directe VPN `10.14.219.2:5433`
- Variable `WINDOWS_NGROK_URL` supprimée de n8n

**Raison** : ngrok URL dynamique (changement après redémarrage), latence réseau
supplémentaire, dépendance externe non nécessaire.

### 9.2 Ajout des variables NODE_FUNCTION_ALLOW_BUILTIN / EXTERNAL

**Problème** : n8n 2.x sandboxe les Code nodes. `require('fs')`, `require('crypto')`,
`require('pg')` tous bloqués par défaut.

**Fix** : ajout dans `docker-compose.yml` :
```yaml
- NODE_FUNCTION_ALLOW_BUILTIN=fs,path,crypto,os,http,https,net
- NODE_FUNCTION_ALLOW_EXTERNAL=pg
```

### 9.3 Remplacement du path absolu pg par require('pg')

**Avant** (non fonctionnel avec ALLOW_EXTERNAL) :
```javascript
const PG_PATH = '/usr/local/lib/node_modules/n8n/node_modules/.pnpm/pg@8.17.0/node_modules/pg';
const { Client } = require(PG_PATH);
```

**Après** :
```javascript
const { Client } = require('pg');
```

### 9.4 Ajout du nœud executeWorkflowTrigger

**Problème** : `SubworkflowOperationError: Missing node to start execution` quand
WF-05 appelle WF-01/02/03/04 via `executeWorkflow`.

**Fix** : ajout du nœud `n8n-nodes-base.executeWorkflowTrigger` (avec connexion vers
le premier nœud de traitement) dans WF-01, WF-02, WF-03, WF-04 **et** WF-05.

### 9.5 Nœuds "Restaurer binaire" entre les deux uploads S3

**Problème** : `This operation expects the node's input data to contain a binary file 'data', but none was found` sur le second nœud S3 (MinIO — Upload latest).

**Cause** : Le nœud S3 Upload retourne la réponse de l'API MinIO (objet JSON),
pas l'item d'entrée avec son binaire.

**Fix** : Nœud Code intercalé `Restaurer binaire` qui re-lit le binaire depuis
le nœud CDC (`$('CDC — ...').first().binary`) et le réattache avant le second upload.
Appliqué à : WF-01, WF-02, WF-03 (×4 tables).

### 9.6 Format de retour json = objet (pas tableau)

**Problème** : `A 'json' property isn't an object [item 0]` dans WF-03.

**Cause** : `return [{ json: rows }]` où `rows` est un `Array`. n8n 2.x valide
que `json` est un objet JS ordinaire.

**Fix** : `return [{ json: { rows, count: rows.length } }]`

Le nœud CDC Hash en aval gère déjà ce format : `if (body.rows) return body.rows;`

### 9.7 Paramètre fieldsToCompare du nœud removeDuplicates

**Problème** : `No fields specified. Please add a field to compare on` dans WF-04.

**Cause** : La configuration utilisait `fields: "origin,destination"` (ancienne API)
alors que n8n 2.x attend `fieldsToCompare: "origin,destination"`.

**Fix** : Renommage du paramètre dans les propriétés du nœud via l'API REST.

### 9.8 Correction du bug de connexion WF-04

**Problème** : `connections.Schedule 07h00 (unknown_connection_source)` lors de la
validation du workflow WF-04.

**Cause** : Le nœud schedule s'appelle `Schedule 08h00` mais la connexion était
enregistrée sous la clé `Schedule 07h00`.

**Fix** : Renommage de la clé dans l'objet `connections` lors de la mise à jour
du workflow via l'API.

### 9.9 Scopes API key n8n

**Problème** : `403 Forbidden` sur tous les endpoints `/api/v1/` malgré une clé API valide.

**Cause** : En n8n 2.21.7, les clés API avec `scopes: null` n'ont **aucun** accès
(comportement cassant par rapport aux versions antérieures où `null` = tous les scopes).

**Fix** : Ajout explicite des scopes dans `user_api_keys` :
```javascript
scopes = ['workflow:list','workflow:read','workflow:update','workflow:activate',
          'workflow:deactivate','execution:list','execution:read','execution:stop', ...]
```

---

## 10. Référence des chemins

### Hôte Linux

| Chemin | Contenu |
|--------|---------|
| `/home/nyanu/Documents/ETL_Projet/` | Racine du projet |
| `/home/nyanu/Documents/ETL_Projet/docker-compose.yml` | Configuration Docker |
| `/home/nyanu/Documents/ETL_Projet/data_sources/` | Fichiers sources CSV/JSON |
| `/home/nyanu/Documents/ETL_Projet/staging/` | Zone de staging |
| `/home/nyanu/Documents/ETL_Projet/staging/flat_files/` | CSV/JSON stagés |
| `/home/nyanu/Documents/ETL_Projet/staging/database/` | Tables PG stagées (JSON) |
| `/home/nyanu/Documents/ETL_Projet/staging/enrichment/` | Données enrichies (distances) |
| `/home/nyanu/Documents/ETL_Projet/staging/_metadata/checksums/` | Checksums CDC |
| `/home/nyanu/Documents/ETL_Projet/n8n_data/database.sqlite` | Base n8n |
| `/home/nyanu/Documents/ETL_Projet/n8n/workflows/` | Sources JSON des workflows |

### Conteneur n8n (ingestion_n8n)

| Chemin | Contenu |
|--------|---------|
| `/data_sources/` | Fichiers sources (bind mount) |
| `/staging/` | Zone de staging (bind mount) |
| `/home/node/.n8n/database.sqlite` | Base SQLite n8n |
| `/staging/_metadata/checksums/` | Checksums CDC |

### MinIO (bucket `bronze`)

| Préfixe | Contenu |
|---------|---------|
| `raw/flat_files/data_csv/` | Versions CSV |
| `raw/flat_files/data_json/` | Versions JSON |
| `raw/database/clients/` | Versions table clients |
| `raw/database/articles/` | Versions table articles |
| `raw/database/salesshipmentheader/` | Versions table header |
| `raw/database/salesshipmentline/` | Versions table ligne |
| `raw/enrichment/distances/` | Versions distances |

---

*Documentation générée le 2026-05-26. Pour toute question : nyanuks@s2.rpn.ch*
