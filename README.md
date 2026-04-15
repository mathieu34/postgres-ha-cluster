# Membres du projet 

Voguie Bathy et Mathieu Ponnou

# Test de charge pgbench — PostgreSQL + Patroni + PgBouncer

| Point clé | Ce qui a été fait |
|---|---|
| **PostgreSQL cluster = performance + disponibilité** | Primary + Replica orchestrés par Patroni, testés sous charge avec pgbench |
| **Master/Replica = architecture la plus utilisée** | Primary gère les écritures, replica streame le WAL — la séparation lectures/écritures (router les SELECT vers le replica) est un intérêt de l'architecture mais n'est pas mise en place ici |
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

| | Sans PgBouncer | Avec PgBouncer |
|---|---|---|
| Clients | 10 000 | 10 000 |
| TPS | — | **463** |
| Latence | — | **21 590 ms** |
| Transactions | — | **20 196** |
| Erreurs | **FATAL: too many clients** | **0** |

À 10 000 clients, sans PgBouncer PostgreSQL rejette toutes les connexions au-delà de `max_connections: 500` — FATAL immédiat. Avec PgBouncer en mode `transaction pooling`, 20 196 transactions passent sur 400 connexions réelles, 0 erreur. La latence à 21 s s'explique par la saturation CPU de la machine locale, pas par l'architecture — sur un serveur dédié les chiffres seraient bien meilleurs.

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
