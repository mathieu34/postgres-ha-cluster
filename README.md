# Test de charge pgbench — PostgreSQL + Patroni + PgBouncer

| Point clé | Ce qui a été fait |
|---|---|
| **PostgreSQL cluster = performance + disponibilité** | Primary + Replica orchestrés par Patroni, testés sous charge avec pgbench |
| **Master/Replica = architecture la plus utilisée** | Primary gère les écritures, replica streame le WAL et peut absorber les lectures |
| **WAL = cœur du système** | `wal_level=replica`, `max_wal_senders=10`, réplication vérifiée via `pg_stat_replication` (state=streaming, lag=0) |
| **HA = Patroni + failover** | Failover démontré : `docker stop primary` → replica devient leader automatiquement en <30s, timeline 1→2 |
| **Monitoring = indispensable** | `pg_stat_replication` (lag, état), `pg_stat_activity` (connexions), API REST Patroni `/cluster` (rôles, état, timeline) |
| **PgBouncer = clé de la scalabilité** | 10 000 clients absorbés en `transaction pooling` (400 connexions réelles, `max_connections: 500`), 0 erreur — sans PgBouncer : FATAL dès 200 connexions |
| **Scale factor = réduction de contention** | `-s 10` génère 10 branches / 100 tellers / 1M comptes, réduit la contention de verrous et améliore le TPS à charge extrême |

---

## Démarrage

```bash
docker compose up -d --build
```

Vérifier que le cluster est prêt :

```bash
curl.exe -s http://localhost:8008/health
```

---

## Initialisation des données

```bash
docker exec -it primary pgbench -U admin -d postgres -i -s 10
```

> À exécuter une seule fois avant les tests. `-s 10` génère ~1 000 000 lignes réparties sur 10 branches et 100 tellers — réduit la contention de verrous à haute charge.

---

## Tests sans PgBouncer (connexion directe — port 5432)

### Baseline x1 — 10 clients

```bash
docker exec -it primary pgbench -U admin -d postgres -c 10 -j 2 -T 30
```

| Métrique | Valeur |
|---|---|
| Clients | 10 |
| TPS | **479** |
| Latence | **20 ms** |
| Erreurs | 0 |

### Simulation x10 — 100 clients

```bash
docker exec -it primary pgbench -U admin -d postgres -c 100 -j 4 -T 30
```

| Métrique | Valeur |
|---|---|
| Clients | 100 |
| TPS | **409** |
| Latence | **244 ms** |
| Erreurs | 0 |

---

## Tests avec PgBouncer (connexion via pool — port 6432)

### Baseline x1 — 10 clients via PgBouncer

```bash
docker exec -it primary pgbench -U admin -d postgres -h pgbouncer -p 5432 -c 10 -j 2 -T 30
```

| Métrique | Valeur |
|---|---|
| Clients | 10 |
| TPS | **414** |
| Latence | **24 ms** |
| Erreurs | 0 |

### Simulation x10 — 100 clients via PgBouncer

```bash
docker exec -it primary pgbench -U admin -d postgres -h pgbouncer -p 5432 -c 100 -j 4 -T 30
```

| Métrique | Valeur |
|---|---|
| Clients | 100 |
| TPS | **391** |
| Latence | **255 ms** |
| Erreurs | 0 |

---

## Test de saturation — la vraie différence PgBouncer

Ce test dépasse `max_connections: 200` pour montrer ce que PgBouncer apporte réellement.

### Sans PgBouncer — 10 000 clients directs

```bash
docker exec -it primary pgbench -U admin -d postgres -c 10000 -j 16 -T 30
```

| Métrique | Valeur |
|---|---|
| Clients | 10 000 |
| Erreurs | **FATAL: sorry, too many clients** |

### Avec PgBouncer — 10 000 clients via pool

```bash
docker exec -it primary pgbench -U admin -d postgres -h pgbouncer -p 5432 -c 10000 -j 16 -T 30
```

| Métrique | Valeur |
|---|---|
| Clients | 10 000 |
| TPS | **463** |
| Latence | **21 590 ms** |
| Transactions | **20 196** |
| Erreurs | **0** |

---

## Analyse des résultats

| | Sans PgBouncer x1 | Sans PgBouncer x10 | Avec PgBouncer x1 | Avec PgBouncer x10 | Sans PgBouncer x1000 | Avec PgBouncer x1000 |
|---|---|---|---|---|---|---|
| Clients | 10 | 100 | 10 | 100 | 10 000 | 10 000 |
| TPS | 479 | 409 | 414 | 391 | — | **463** |
| Latence | 20 ms | 244 ms | 24 ms | 255 ms | — | **21 590 ms** |
| Erreurs | 0 | 0 | 0 | 0 | **FATAL** | **0** |

À 10 et 100 clients les résultats sont proches — le goulot est la puissance brute de la machine. La vraie différence apparaît à 10 000 clients : sans PgBouncer PostgreSQL rejette tout au-delà de `max_connections: 500`. Avec PgBouncer 20 196 transactions passent en mode `transaction pooling` (400 connexions réelles, scale=10), 0 erreur — la latence à 21 s s'explique par la saturation CPU de la machine locale, pas par l'architecture.

**Face à une montée x10 du trafic :** PgBouncer absorbe les connexions pour éviter la saturation. Le replica peut recevoir les SELECT si l'application route les lectures vers le port 5433 — le primary ne traite alors plus que les écritures.

**Piste d'optimisation :** passer `synchronous_commit = off` dans la config PostgreSQL permettrait de gagner ~30-40% de TPS supplémentaire — PostgreSQL n'attendrait plus la confirmation d'écriture WAL sur disque avant de valider chaque transaction. Acceptable en environnement de test, risqué en production (perte possible des dernières transactions en cas de crash).

---

## Tests de réplication

### 1. Vérifier que les données se répliquent en temps réel

```bash
# Créer une table sur le primary
docker exec -it primary psql -U admin -d postgres -c "CREATE TABLE test_replication (id SERIAL, message TEXT, created_at TIMESTAMP DEFAULT NOW());"

# Insérer une ligne sur le primary
docker exec -it primary psql -U admin -d postgres -c "INSERT INTO test_replication (message) VALUES ('Live WAL streaming test!');"

# Lire immédiatement sur le replica — la ligne doit apparaître
docker exec -it replica psql -U admin -d postgres -c "SELECT * FROM test_replication;"

# Vérifier l'état de la réplication (state=streaming, lag=0)
docker exec -it primary psql -U admin -d postgres -c "SELECT * FROM pg_stat_replication;"
```

### 2. Tester le failover automatique Patroni

```bash
# Vérifier l'état initial — primary est leader, timeline 1
curl.exe -s http://localhost:8008/cluster

# Couper le primary
docker stop primary

# Attendre ~20s puis vérifier — replica est devenu leader, timeline 2
curl.exe -s http://localhost:8009/cluster

# Relancer le primary — il rejoint comme replica
docker start primary
```

> Patroni détecte la panne, consulte etcd et promeut le replica automatiquement. L'ancien primary revient comme replica du nouveau leader sans intervention manuelle.

---

## Monitoring — commandes utiles

À lancer dans un second terminal pour observer l'état du cluster en temps réel :

```bash
# Rôles et état du cluster (leader / replica / timeline)
curl.exe -s http://localhost:8008/cluster

# Nombre de connexions actives sur le primary
docker exec primary psql -U admin -c "SELECT count(*) FROM pg_stat_activity;"

# Lag de réplication WAL (state, sent_lsn, replay_lsn)
docker exec primary psql -U admin -c "SELECT * FROM pg_stat_replication;"
```

---

## Nettoyage

```bash
docker compose down -v
```
