#!/usr/bin/env bash
# Writes an encrypted, compressed archive of env/ to a folder, then removes the oldest ones.
# env/ holds the only copy of the passwords of the database and of the API: without it, a
# database restored from a backup could no longer be reached by anyone.
#
# Encrypted with the same public key as the backups of the database: whoever holds the private
# key can already read all the data, which these passwords only give access to.

set -euo pipefail

readonly BACKUP_RETENTION_COUNT="${BACKUP_RETENTION_COUNT:-30}"

# The archive keeps the permissions of the files, so that a restoration gives back the same ones.
# The .partial files are left out: sync-env.sh only leaves them after an interrupted run.
readonly ARCHIVE_COMMAND="tar --create --gzip --file - --exclude='*.partial' env"

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
  Sauvegarde le dossier env/ (configuration et mots de passe), le compresse et le chiffre
  avec la clé publique de env/backup-recipients.txt, la même que pour la base.
  Les ${BACKUP_RETENTION_COUNT} dernières sauvegardes du dossier sont gardées
  (BACKUP_RETENTION_COUNT pour changer ce nombre).

Source : le dossier floraccess-wrapper qui contient env/.
  - Un chemin sur cette machine. Par défaut : ${project_directory}
  - Ou [utilisateur@]serveur:chemin, pour passer par SSH. Le chemin est absolu, ou relatif
    au dossier personnel. L'archive est chiffrée sur le serveur : seule la version
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

# Not "floraccess_": that prefix belongs to the backups of the database, which backup.sh removes
backup_file="${output_directory}/floraccess-env_$(date +%Y-%m-%d_%H-%M-%S).tar.gz.age"
readonly backup_file

write_backup_from_source "${backup_file}" "${ARCHIVE_COMMAND} | ${ENCRYPT_COMMAND}"

remove_oldest_backups "${output_directory}" 'floraccess-env_*.tar.gz.age' "${BACKUP_RETENTION_COUNT}"

echo "Backup written: ${backup_file}"
