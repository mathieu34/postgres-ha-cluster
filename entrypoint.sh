#!/bin/bash
# Script d'entrée exécuté au démarrage du conteneur (en tant que root)
# Rôle : corriger les permissions du répertoire de données puis lancer Patroni

set -e  # Arrêter le script immédiatement si une commande échoue

# PostgreSQL exige que le répertoire de données soit en mode 0700 (rwx------)
# Les volumes Docker sont créés avec des permissions 0755 par défaut → erreur au démarrage
# On corrige ça ici avant que Patroni essaie d'initialiser PostgreSQL
if [ -d /var/lib/postgresql/data ]; then
    chmod 700 /var/lib/postgresql/data
fi

# Lancer Patroni en tant qu'utilisateur "postgres" (et non root) pour des raisons de sécurité
# gosu est l'équivalent de "su" mais compatible avec Docker (pas de signal trapping issues)
# Patroni va ensuite initialiser PostgreSQL et gérer tout le cycle de vie du nœud
exec gosu postgres patroni /etc/patroni/patroni.yml
