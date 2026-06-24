# ETL_Projet — Phase A : Ingestion n8n → MinIO Bronze

## 🏗️ Architecture des flux

```
[Source Windows 192.168.1.27]
    ├── ngrok HTTP ──► data.csv  ──► Workflow 01 ──► MinIO bronze/raw/flat_files/csv/
    ├── ngrok HTTP ──► data.json ──► Workflow 02 ──► MinIO bronze/raw/flat_files/json/
    ├── ngrok TCP  ──► PostgreSQL ─► Workflow 03 ──► MinIO bronze/raw/database/
    └── Google API ──────────────── Workflow 04 ──► MinIO bronze/raw/enrichment/distance_matrix/
```

## 📁 Structure MinIO Bronze cible

```
bronze/
└── raw/
    ├── flat_files/
    │   ├── csv/
    │   │   └── data_YYYY-MM-DD.csv
    │   └── json/
    │       └── data_YYYY-MM-DD.json
    ├── database/
    │   ├── clients_YYYY-MM-DD.json
    │   ├── commandes_YYYY-MM-DD.json
    │   ├── articles_YYYY-MM-DD.json
    │   └── livraisons_YYYY-MM-DD.json
    └── enrichment/
        └── distance_matrix/
            └── enriched_YYYY-MM-DD.json
```

---

## ⚙️ ÉTAPE 1 — Configurer les Credentials dans n8n

Avant d'importer les workflows, créer ces 2 credentials dans n8n
(Menu : **Settings → Credentials → + Add Credential**)

---

### Credential A : "MinIO S3" (type AWS)

| Champ                  | Valeur                          |
|------------------------|---------------------------------|
| Credential Name        | `MinIO S3`                      |
| Region                 | `us-east-1`                     |
| Access Key ID          | `nyanu`                         |
| Secret Access Key      | `nyanu`                         |
| Custom Endpoint        | `http://10.14.210.159:9000`     |
| ✅ Force Path Style    | **Activé** (obligatoire MinIO)  |

---

### Credential B : "PostgreSQL ngrok" (type PostgreSQL)

| Champ       | Valeur                                      |
|-------------|---------------------------------------------|
| Name        | `PostgreSQL ngrok`                          |
| Host        | `0.tcp.ngrok.io`                            |
| Port        | `⚠️ VOTRE_PORT_NGROK_TCP` (ex: 14785)       |
| Database    | `database_extern_local`                     |
| User        | `postgres`                                  |
| Password    | `⚠️ VOTRE_MOT_DE_PASSE_POSTGRES`            |
| SSL         | `Disable`                                   |

> **⚠️ Note critique :** Le port ngrok TCP change à chaque redémarrage du tunnel.
> Vérifiez-le dans le dashboard ngrok : https://dashboard.ngrok.com/tunnels
> Mettez à jour ce credential avant chaque exécution si le tunnel a redémarré.

---

## 📥 ÉTAPE 2 — Importer les workflows

1. Ouvrir n8n → http://10.14.210.159:5678
2. Menu latéral → **Workflows → + Add Workflow**
3. En haut à droite → **⋮ (trois points) → Import from File**
4. Sélectionner le fichier JSON souhaité
5. Après import : aller dans chaque nœud S3/PostgreSQL et **re-sélectionner** le credential correspondant
6. Cliquer **Save**

---

## 🚀 ÉTAPE 3 — Ordre d'exécution recommandé

```
01 (CSV)  ──┐
02 (JSON) ──┤──► attendre fin ──► 03 (PostgreSQL) ──► 04 (Distance Matrix)
```

Le Workflow 04 lit les données déjà déposées par le Workflow 03 dans MinIO.
Lancer 03 en premier, puis 04.

---

## ✅ Validation

Après exécution, vérifier dans MinIO (http://10.14.210.159:9001) :
- Bucket `bronze` → dossier `raw/` → sous-dossiers présents avec les fichiers datés
