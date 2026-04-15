#!/bin/bash
# ─────────────────────────────────────────────────────────
# setup.sh — Initialisation du nœud REPLICA
#
# Au premier démarrage : clone le primary via pg_basebackup
#   - pg_basebackup copie les fichiers de données ET le WAL en cours
#   - -R génère automatiquement le fichier standby.signal + recovery config
#   - --wal-method=stream : le WAL est streamé en parallèle pendant le backup
#
# Aux démarrages suivants : les données existent déjà, on démarre directement
# ─────────────────────────────────────────────────────────
set -e

echo "==> Vérification du répertoire de données..."

if [ -z "$(ls -A /var/lib/postgresql/data 2>/dev/null)" ]; then
    echo "==> Répertoire vide, clonage du primary..."

    # Attendre que le primary soit prêt à accepter des connexions
    until pg_isready -h primary -U admin; do
        echo "    En attente du primary..."
        sleep 2
    done

    echo "==> Lancement de pg_basebackup..."
    # -h primary      : se connecte au conteneur "primary"
    # -U replicator   : user avec le droit REPLICATION
    # -R              : crée standby.signal + postgresql.auto.conf avec primary_conninfo
    # --wal-method=stream : streame le WAL pendant le backup (cohérence garantie)
    PGPASSWORD=replicator pg_basebackup \
        -h primary \
        -D /var/lib/postgresql/data \
        -U replicator \
        -P \
        -R \
        --wal-method=stream

    echo "==> Clonage terminé !"
else
    echo "==> Répertoire déjà initialisé, démarrage direct."
fi

# Démarrer PostgreSQL normalement (Patroni prend ensuite le relais)
exec docker-entrypoint.sh postgres
