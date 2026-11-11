#!/usr/bin/env bash
# Helpers shared by the backup scripts, sourced after env-file.sh.
#
# A backup is read from a "source": a folder of floraccess-wrapper, on this machine or on a server
# reached through SSH. The data is encrypted at the source, so only encrypted bytes go through
# SSH, and the server needs nothing but what deploy.sh already needs.
#
# Each script that sources this file defines print_usage.

readonly ENCRYPT_COMMAND="age --encrypt --recipients-file ${BACKUP_RECIPIENTS_FILE@Q}"

# Exit statuses of the check run at the source, so that each problem gets its own message
readonly MISSING_ENV_STATUS=10
readonly CANNOT_ENCRYPT_STATUS=11

# Set by parse_backup_arguments
backup_source=""
source_host=""
source_path=""
ssh_port=""
output_directory=""


# Same rule as scp: a colon before any slash means [user@]host:path
parse_backup_source() {
    local source="$1"

    if [[ "${source}" =~ ^([^/:]+):(.*)$ ]]; then
        source_host="${BASH_REMATCH[1]}"
        source_path="${BASH_REMATCH[2]}"

        # The remote shell starts in the home folder, so "~/" means the same as nothing.
        # Removed here because the path is quoted, and a quoted "~" would not be expanded.
        case "${source_path}" in
            "~")
                source_path=""
                ;;
            "~/"*)
                source_path="${source_path#\~/}"
                ;;
        esac

        source_path="${source_path:-.}"
    else
        source_host=""
        source_path="${source}"
    fi
}


is_remote_source() {
    [[ -n "${source_host}" ]]
}


parse_backup_arguments() {
    local default_wrapper_directory="$1"
    shift

    local option
    local OPTIND
    local given_source=""
    local script_name
    script_name="$(basename "$0")"

    output_directory="${default_wrapper_directory}/backups"

    # getopts stops at the first argument that is not an option: started again after the
    # source, so that the options can come before or after it
    while (( $# > 0 )); do
        OPTIND=1

        while getopts ":p:o:h" option; do
            case "${option}" in
                p)
                    ssh_port="${OPTARG}"
                    ;;
                o)
                    output_directory="${OPTARG}"
                    ;;
                h)
                    print_usage
                    exit 0
                    ;;
                :)
                    echo "L'option -${OPTARG} attend une valeur. Voir : ${script_name} -h" >&2
                    exit 1
                    ;;
                *)
                    echo "Option inconnue : -${OPTARG}. Voir : ${script_name} -h" >&2
                    exit 1
                    ;;
            esac
        done
        shift $((OPTIND - 1))

        if (( $# == 0 )); then
            break
        fi

        if [[ -n "${given_source}" ]]; then
            echo "Une seule source est attendue. Voir : ${script_name} -h" >&2
            exit 1
        fi

        given_source="$1"
        shift
    done

    backup_source="${given_source:-${default_wrapper_directory}}"
    parse_backup_source "${backup_source}"

    if [[ -n "${ssh_port}" ]] && ! is_remote_source; then
        echo "L'option -p ne sert qu'avec une source SSH ([utilisateur@]serveur:chemin)." >&2
        exit 1
    fi

    if [[ -n "${ssh_port}" && ! "${ssh_port}" =~ ^[0-9]+$ ]]; then
        echo "Port SSH invalide : ${ssh_port}" >&2
        exit 1
    fi
}


# Runs a shell command from the folder of the source. Its standard output comes back here.
run_at_source() {
    local command="$1"
    local command_in_source="cd -- ${source_path@Q} && ${command}"

    if ! is_remote_source; then
        bash -o pipefail -c "${command_in_source}"
        return
    fi

    # Without -p, ssh keeps the port of ~/.ssh/config, or 22
    local ssh_options=()
    if [[ -n "${ssh_port}" ]]; then
        ssh_options+=(-p "${ssh_port}")
    fi

    ssh "${ssh_options[@]}" -- "${source_host}" "bash -o pipefail -c ${command_in_source@Q}"
}


# One check, so a remote source asks for its password only once before the backup itself
require_backup_source() {
    local status=0

    run_at_source "
        test -d env || exit ${MISSING_ENV_STATUS}
        ${ENCRYPT_COMMAND} < /dev/null > /dev/null 2>&1 || exit ${CANNOT_ENCRYPT_STATUS}
    " || status=$?

    case "${status}" in
        0)
            return
            ;;
        "${MISSING_ENV_STATUS}")
            echo "Error: no env/ folder in ${backup_source}" >&2
            ;;
        "${CANNOT_ENCRYPT_STATUS}")
            echo "Error: in ${backup_source}, ${BACKUP_ENCRYPTION_REQUIREMENT}" >&2
            ;;
        *)
            echo "Error: cannot reach ${backup_source}" >&2
            ;;
    esac

    exit 1
}


# Written aside, then renamed: an interrupted backup must never pass for a valid one.
# The partial file is removed on any exit, and no longer exists once renamed.
# Its local variables avoid the names of the scripts, which hold readonly ones.
write_backup_from_source() {
    local destination_file="$1"
    local command="$2"
    local partial_destination_file="${destination_file}.partial"

    # Encryption protects the content: these permissions also keep the dates and sizes private
    umask 077
    mkdir -p -- "$(dirname "${destination_file}")"

    trap "rm -f -- ${partial_destination_file@Q}" EXIT

    if ! run_at_source "${command}" > "${partial_destination_file}"; then
        echo "Error: the backup failed in ${backup_source}, nothing was written" >&2
        exit 1
    fi

    mv -- "${partial_destination_file}" "${destination_file}"
}


# The date in the file names sorts them from the oldest to the newest.
remove_oldest_backups() {
    local folder="$1"
    local file_pattern="$2"
    local retention_count="$3"

    find "${folder}" -maxdepth 1 -name "${file_pattern}" -printf '%f\n' \
        | sort -r \
        | tail -n +"$((retention_count + 1))" \
        | while read -r outdated_backup; do
            rm -f -- "${folder}/${outdated_backup}"
        done
}
