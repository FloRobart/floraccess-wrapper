#!/usr/bin/env bash
# Writes an encrypted, compressed dump of the database to a folder, then removes the oldest ones.
# The database runs on this machine, or on a server reached through SSH: the dump is encrypted
# there, and only a public key is on that machine. It can write backups, but not read them.

set -euo pipefail

readonly BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-30}"

# With an explicit project name, Compose does not read the files of the repositories on
# GitHub, so a backup still works when GitHub is down
readonly COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-floraccess}"

# Without the privileges: they name the role of the API, which a new empty database does not have
# yet, so the restoration would fail. floraccess-api-role grants them again at the next deployment.
# shellcheck disable=SC2016 # Expanded by the shell of the database container
readonly PG_DUMP_COMMAND='pg_dump --no-privileges -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"'

project_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly project_directory

# shellcheck source=lib/env-file.sh
source "${project_directory}/scripts/lib/env-file.sh"
# shellcheck source=lib/backup-helpers.sh
source "${project_directory}/scripts/lib/backup-helpers.sh"


print_usage() {
    cat <<EOF
Utilisation : $(basename "$0") [-h] [-p port] [-o dossier] [source]

À quoi sert ce script :
  Sauvegarde la base de FlorAccess, la compresse et la chiffre avec la clé publique de
  env/backup-recipients.txt. Les ${BACKUP_RETENTION_COUNT} dernières sauvegardes du dossier sont gardées
  (BACKUP_RETENTION_COUNT pour changer ce nombre).

Source : le dossier floraccess-wrapper où tourne la base.
  - Un chemin sur cette machine. Par défaut : ${project_directory}
  - Ou [utilisateur@]serveur:chemin, pour passer par SSH. Le chemin est absolu, ou relatif
    au dossier personnel. La sauvegarde est chiffrée sur le serveur : seule la version
    chiffrée passe par SSH, et age n'est pas nécessaire sur cette machine.

Options :
  -p port      Port SSH. Par défaut, celui de ~/.ssh/config, sinon 22.
  -o dossier   Où écrire la sauvegarde. Par défaut : ${project_directory}/backups
  -h           Affiche cette aide.

Exemples :
  $(basename "$0")
  $(basename "$0") -p 2222 -o ~/sauvegardes floris@florobart.fr:/srv/floraccess-wrapper
EOF
}


parse_backup_arguments "${project_directory}" "$@"
require_backup_source

backup_file="${output_directory}/floraccess_$(date +%Y-%m-%d_%H-%M-%S).sql.gz.age"
readonly backup_file

write_backup_from_source "${backup_file}" \
    "docker compose --project-name ${COMPOSE_PROJECT@Q} exec -T floraccess-database sh -c ${PG_DUMP_COMMAND@Q} \
        | gzip \
        | ${ENCRYPT_COMMAND}"

remove_oldest_backups "${output_directory}" 'floraccess_*.sql.gz.age' "${BACKUP_RETENTION_COUNT}"

echo "Backup written: ${backup_file}"
