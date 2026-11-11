#!/usr/bin/env bash
# Keeps env/ in line with the .env.example of the latest release of each repository:
#   - a missing .env is created from that example, with the production values below;
#   - an existing .env is never modified, but a variable it lacks is reported;
#   - a missing password of the role of the API is generated, also for an existing installation;
#   - a missing JWT signing key is generated, and a missing mail password is reported;
#   - backups that could not be encrypted are reported.
#
# Exits with status 1 when something needs a look, so a deployment stops before it starts.

set -euo pipefail

readonly GITHUB_FILES_URL="https://raw.githubusercontent.com/FloRobart"

# Same branch as the includes of docker-compose.yml
readonly RELEASE_BRANCH="main"

readonly APP_PUBLIC_URL="https://floraccess.florobart.fr"
readonly API_PUBLIC_URL="https://api.floraccess.florobart.fr"

# The web applications that call the API from a browser: the administration panel, and the
# applications that sign their users in with FlorAccess
readonly ALLOWED_BROWSER_ORIGINS="${APP_PUBLIC_URL},https://app.econoris.fr"

project_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly project_directory

# shellcheck source=lib/env-file.sh
source "${project_directory}/scripts/lib/env-file.sh"

temporary_directory="$(mktemp -d)"
readonly temporary_directory
trap 'rm -rf -- "${temporary_directory}"' EXIT

needs_review=false


# Receives the file being built: the message names the final one, the only one left to edit
configure_proxy() {
    echo "To fill in by hand: LETSENCRYPT_EMAIL in env/proxy/.env"
}


configure_database() {
    # PostgreSQL only applies this password when its volume is created: a new one would not
    # reach an existing database, and the old one, then lost, would be the only one that works.
    if [[ -f "${DATABASE_PASSWORD_FILE}" ]]; then
        echo "Kept: ${DATABASE_PASSWORD_FILE}"
        return
    fi

    write_secret_file "${DATABASE_PASSWORD_FILE}" "$(generate_database_password)"
}


# Generated once, then kept: floraccess-api-role applies it in PostgreSQL on every deployment.
# Nothing to fill in by hand, so its creation does not stop the deployment.
ensure_api_database_password() {
    if [[ -f "${API_DATABASE_PASSWORD_FILE}" ]]; then
        return
    fi

    write_secret_file "${API_DATABASE_PASSWORD_FILE}" "$(generate_database_password)"
    echo "Created: ${API_DATABASE_PASSWORD_FILE}"
}


# Generated for a new installation. An installation that moves here must put its current key in
# this file instead: a new key invalidates every JWT already given, which signs every user out
# of every application that uses FlorAccess. So its creation stops the deployment.
ensure_jwt_signing_key() {
    if is_secret_file_filled "${API_JWT_SIGNING_KEY_FILE}"; then
        return
    fi

    write_secret_file "${API_JWT_SIGNING_KEY_FILE}" "$(generate_jwt_signing_key)"
    echo "Created: ${API_JWT_SIGNING_KEY_FILE} (to replace with the current key if an existing installation moves here)"
    needs_review=true
}


# Given by the mail provider, so it cannot be generated. The file is created empty so that Compose
# finds it, and the deployment stops until it is filled in: the API sends the login codes by email.
ensure_mail_password() {
    if is_secret_file_filled "${API_MAIL_PASSWORD_FILE}"; then
        return
    fi

    if [[ ! -f "${API_MAIL_PASSWORD_FILE}" ]]; then
        write_secret_file "${API_MAIL_PASSWORD_FILE}" ""
    fi

    echo "To fill in by hand: the password of the mail account, alone in ${API_MAIL_PASSWORD_FILE}"
    needs_review=true
}


configure_api() {
    local env_file="$1"

    # Only for the clarity of the file: docker-compose.override.yml forces this role anyway
    set_env_value "${env_file}" DB_USER "${API_DATABASE_ROLE}"

    set_env_value "${env_file}" APP_ENV prod
    set_env_value "${env_file}" BASE_URL "${API_PUBLIC_URL}"
    set_env_value "${env_file}" CORS_ALLOWED_ORIGINS "${ALLOWED_BROWSER_ORIGINS}"

    echo "To fill in by hand: MAIL_USERNAME in env/api/.env"
    echo "To check by hand: CORS_ALLOWED_ORIGINS in env/api/.env, every web application that uses FlorAccess"
}


configure_app() {
    local env_file="$1"

    set_env_value "${env_file}" DATA_URL "${API_PUBLIC_URL}"

    # nginx serves this file to every visitor, from a user that must be able to read it
    chmod 644 "${env_file}"
}


create_env_file() {
    local env_name="$1"
    local example_file="$2"
    local env_file="env/${env_name}/.env"

    # Built aside, then moved in place: an interrupted run must not leave a .env holding the
    # values of the example, which the next run would keep as it is.
    # Same folder as the .env, so that mv only renames it and cannot be interrupted halfway.
    local partial_env_file="${env_file}.partial"

    mkdir -p "env/${env_name}"
    install -m 600 "${example_file}" "${partial_env_file}"
    "configure_${env_name}" "${partial_env_file}"
    mv -- "${partial_env_file}" "${env_file}"

    echo "Created: ${env_file}"
    needs_review=true
}


report_missing_variables() {
    local env_file="$1"
    local example_file="$2"
    local variable_name

    while read -r variable_name; do
        if ! grep -q "^${variable_name}=" "${env_file}"; then
            echo "Missing in ${env_file}: ${variable_name}"
            needs_review=true
        fi
    done < <(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "${example_file}")
}


sync_env_file() {
    local env_name="$1"
    local repository="$2"
    local example_file="${temporary_directory}/${env_name}.env.example"

    curl --fail --silent --show-error --location --output "${example_file}" \
        "${GITHUB_FILES_URL}/${repository}/${RELEASE_BRANCH}/.env.example"

    if [[ -f "env/${env_name}/.env" ]]; then
        report_missing_variables "env/${env_name}/.env" "${example_file}"
        return
    fi

    create_env_file "${env_name}" "${example_file}"
}


cd "${project_directory}"

sync_env_file proxy floraccess-proxy
sync_env_file database floraccess-database
sync_env_file api floraccess-api
sync_env_file app floraccess-app

ensure_api_database_password
ensure_jwt_signing_key
ensure_mail_password
write_migrations_env

# A deployment backs up the database: better to find out before anything is touched
if ! can_encrypt_backups; then
    echo "To fix: ${BACKUP_ENCRYPTION_REQUIREMENT}"
    needs_review=true
fi

if [[ "${needs_review}" == true ]]; then
    echo "Review env/, then run the command again."
    exit 1
fi
