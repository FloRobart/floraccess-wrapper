#!/usr/bin/env bash
# Changes the passwords of the database in PostgreSQL and in env/database/secrets/: the one of its
# owner and the one of the role of the API. Then restarts the API, which reads its password from there.

set -euo pipefail

project_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly project_directory

# shellcheck source=lib/env-file.sh
source "${project_directory}/scripts/lib/env-file.sh"


print_usage() {
    cat <<EOF
Usage: $(basename "$0") [-h] [new_password]

Changes the passwords of the database in PostgreSQL and in env/database/secrets/:
the one of its owner and the one of the role of the API (${API_DATABASE_ROLE}).
Then restarts the API. The database must be running.

Arguments:
  new_password  The new password of the owner, with letters and digits only.
                Generated when omitted, which is recommended: a password given
                here stays in the shell history. The password of the API is
                always generated.

Options:
  -h            Shows this help.

The passwords are never displayed. They can be read in ${DATABASE_PASSWORD_FILE}
and ${API_DATABASE_PASSWORD_FILE}.
EOF
}


exit_with_error() {
    local message="$1"

    echo "Error: ${message}" >&2
    echo "See: $(basename "$0") -h" >&2
    exit 1
}


# The password goes unescaped in a connection URL and in the SQL statement below
check_password_format() {
    local password="$1"

    if [[ ! "${password}" =~ ^[A-Za-z0-9]+$ ]]; then
        exit_with_error "the password must only contain letters and digits."
    fi
}


# Once PostgreSQL has changed, a file that cannot be updated would break the API
check_password_file() {
    local password_file="$1"

    if [[ ! -w "${password_file}" ]]; then
        exit_with_error "${password_file} does not exist or cannot be written."
    fi
}


# Sent through standard input: a command argument would be visible in the process list
change_password_in_postgresql() {
    local role="$1"
    local new_password="$2"

    printf "ALTER ROLE %s PASSWORD '%s';\n" "${role}" "${new_password}" \
        | docker compose exec -T floraccess-database \
            sh -c 'psql --quiet -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"'
}


# Only the API, which reads its password when it starts. PostgreSQL reads the file of the owner at
# its first start only, and floraccess-migrate and floraccess-api-role read the new files at the next
# deployment. Forced, because Compose does not detect a change in a mounted file.
restart_api() {
    docker compose up --detach --wait --no-deps --force-recreate floraccess-api
}


while getopts ":h" option; do
    case "${option}" in
        h)
            print_usage
            exit 0
            ;;
        *)
            exit_with_error "unknown option -${OPTARG}."
            ;;
    esac
done
shift "$((OPTIND - 1))"

if [[ "$#" -gt 1 ]]; then
    exit_with_error "too many arguments."
fi

owner_password="${1:-$(generate_database_password)}"
readonly owner_password

api_password="$(generate_database_password)"
readonly api_password

check_password_format "${owner_password}"

cd "${project_directory}"

check_password_file "${DATABASE_PASSWORD_FILE}"
check_password_file "${API_DATABASE_PASSWORD_FILE}"

# The API first: if its role does not exist yet, the script stops before changing anything.
# Restarted at once, so that a failure on the owner cannot leave it with an outdated password.
change_password_in_postgresql "${API_DATABASE_ROLE}" "${api_password}"
write_secret_file "${API_DATABASE_PASSWORD_FILE}" "${api_password}"
restart_api

change_password_in_postgresql CURRENT_USER "${owner_password}"
write_secret_file "${DATABASE_PASSWORD_FILE}" "${owner_password}"
write_migrations_env

echo "Database passwords changed. They can be read in ${DATABASE_PASSWORD_FILE} and ${API_DATABASE_PASSWORD_FILE}."
