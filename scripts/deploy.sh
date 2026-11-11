#!/usr/bin/env bash
# Starts FlorAccess, or updates it to the latest release of each repository.
# Safe to run again: it only recreates what changed and only applies pending migrations.

set -euo pipefail

project_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly project_directory


print_usage() {
    cat <<EOF
Utilisation : $(basename "$0") [-h]

À quoi sert ce script :
  Démarre FlorAccess, ou le met à jour vers la dernière release de chaque dépôt.
  Tout est mis à jour d'un coup : Traefik, base, migrations, API et panel d'administration.

  Dans l'ordre, il :
    1. vérifie env/ et s'arrête s'il manque quelque chose ;
    2. télécharge les images ;
    3. sauvegarde et chiffre la base, si elle tourne déjà ;
    4. démarre tout et applique les migrations manquantes ;
    5. recrée le conteneur du panel d'administration.

  On peut le relancer sans risque : seul ce qui a changé redémarre, en plus du
  panel d'administration, coupé un court instant à chaque lancement.

Ne pas l'utiliser :
  - Juste après un merge sur main : attendre la fin de la CI. Sinon, il prendrait le
    nouveau docker-compose.yml avec l'ancienne image.
  - Si la CI a échoué après un merge : main est alors en avance sur la dernière release.
  - Pour redémarrer un service ou regarder son état : il mettrait aussi tout à jour.
    Utiliser plutôt : docker compose -p floraccess restart <service>
  - Si un seul dépôt doit être mis à jour : il prend la dernière release de tous.
  - Avant de restaurer une ancienne sauvegarde : il créerait des tables qui entreraient
    en conflit avec elle. Voir "Reprendre une ancienne sauvegarde" dans le README.
  - Sur un poste de travail, sans avoir défini COMPOSE_FILE : il se lancerait en mode
    production. Voir "Essayer en local" dans le README.

Il échoue si GitHub ou le registre Docker sont injoignables. Ce qui tourne n'est pas touché.

Options :
  -h    Affiche cette aide.
EOF
}


is_database_running() {
    [[ -n "$(docker compose ps --status running --quiet floraccess-database)" ]]
}


while getopts ":h" option; do
    case "${option}" in
        h)
            print_usage
            exit 0
            ;;
        *)
            echo "Option inconnue : -${OPTARG}. Voir : $(basename "$0") -h" >&2
            exit 1
            ;;
    esac
done

cd "${project_directory}"

"${project_directory}/scripts/sync-env.sh"

# Pull first, so a missing image stops the deployment before anything is touched
docker compose pull

# A first installation has nothing to back up yet
if is_database_running; then
    "${project_directory}/scripts/backup.sh"
fi

# Stops with an error if a migration fails or a service does not become healthy
docker compose up --detach --wait --remove-orphans

# Compose does not detect a change in a mounted file, and the running container would keep
# serving the previous version. This container is stateless, so recreating it costs nothing.
docker compose up --detach --wait --no-deps --force-recreate floraccess-app

docker compose ps --all
