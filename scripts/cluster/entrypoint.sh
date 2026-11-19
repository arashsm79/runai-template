#!/usr/bin/env bash

set -Eeuo pipefail

# Validate the runtime identity supplied by Run:ai.
# The container runs as a non-root UID assigned by the cluster, so UID and GID
# are read from the process rather than from the submission.
: "${LDAP_USER:?LDAP_USER must be set by the workload submission}"
: "${SSH_PASSWORD:?SSH_PASSWORD must be set by the workload submission}"

if [[ ! "${LDAP_USER}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    printf '%s\n' 'LDAP_USER contains unsupported characters' >&2
    exit 1
fi

runtime_uid="$(id -u)"
runtime_gid="$(id -g)"

# The identity is taken from the process, so there is no account to serve when
# the container is root.
if [[ "${runtime_uid}" -eq 0 ]]; then
    printf '%s\n' 'Refusing to run as root: a non-root cluster identity is required' >&2
    exit 1
fi

# Configure the persistent user environment.
# Keep every user-specific tool directory below the submitted HOME.
if [[ -z "${HOME:-}" ]]; then
    printf '%s\n' 'HOME must be set by the workload submission' >&2
    exit 1
fi

export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-${XDG_CACHE_HOME}/uv}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-${HOME}/.uv}"
export VSCODE_AGENT_FOLDER="${VSCODE_AGENT_FOLDER:-${HOME}/.vscode-server}"

mkdir -p "${HOME}" 2>/dev/null || true
if [[ ! -w "${HOME}" ]]; then
    printf 'HOME (%s) must be writable by uid %s\n' "${HOME}" "${runtime_uid}" >&2
    exit 1
fi

mkdir -p \
    "${XDG_CONFIG_HOME}" \
    "${XDG_CACHE_HOME}" \
    "${XDG_DATA_HOME}" \
    "${XDG_STATE_HOME}" \
    "${UV_CACHE_DIR}" \
    "${UV_PYTHON_INSTALL_DIR}" \
    "${VSCODE_AGENT_FOLDER}"

# The runtime identity has no passwd entry and adding one needs root, so serve
# one through nss_wrapper. The database starts from the image's own files, which
# keeps image users resolvable, and appends the runtime identity with the SSH
# password hash (sshd falls back to it because /etc/shadow stays unreadable).
identity_dir="${HOME}/.nss"
sshd_dir="${HOME}/.ssh"
mkdir -p "${identity_dir}" "${sshd_dir}"
chmod 700 "${identity_dir}" "${sshd_dir}"

# sshd starts login sessions with a sanitized environment, so the login shell
# re-applies the nss_wrapper environment before handing over to bash.
login_shell="${identity_dir}/shell"
{
    printf '#!/bin/sh\n'
    printf 'export LD_PRELOAD=libnss_wrapper.so\n'
    printf 'export NSS_WRAPPER_PASSWD=%q\n' "${identity_dir}/passwd"
    printf 'export NSS_WRAPPER_GROUP=%q\n' "${identity_dir}/group"
    printf 'exec /bin/bash "$@"\n'
} > "${login_shell}"
chmod 755 "${login_shell}"

password_hash="$(printf '%s\n' "${SSH_PASSWORD}" | openssl passwd -6 -stdin)"
unset SSH_PASSWORD

awk -F: -v uid="${runtime_uid}" -v name="${LDAP_USER}" \
    '$1 != name && $3 + 0 != uid + 0' /etc/passwd > "${identity_dir}/passwd"
printf '%s:%s:%s:%s:runtime:%s:%s\n' \
    "${LDAP_USER}" \
    "${password_hash}" \
    "${runtime_uid}" \
    "${runtime_gid}" \
    "${HOME}" \
    "${login_shell}" >> "${identity_dir}/passwd"
awk -F: -v gid="${runtime_gid}" '$3 + 0 != gid + 0' /etc/group > "${identity_dir}/group"
printf 'runtime-%s:x:%s:\n' "${runtime_gid}" "${runtime_gid}" >> "${identity_dir}/group"
chmod 600 "${identity_dir}/passwd"

# Everything that resolves accounts needs the wrapper, ssh-keygen included.
nss_env=(
    "LD_PRELOAD=libnss_wrapper.so"
    "NSS_WRAPPER_PASSWD=${identity_dir}/passwd"
    "NSS_WRAPPER_GROUP=${identity_dir}/group"
)

# Generate persistent host keys and configure sshd.
# The keys live in HOME so clients keep a stable fingerprint across restarts.
for key_type in ed25519 rsa; do
    key_file="${sshd_dir}/ssh_host_${key_type}_key"
    if [[ ! -s "${key_file}" ]]; then
        if [[ "${key_type}" == rsa ]]; then
            env "${nss_env[@]}" ssh-keygen -q -t rsa -b 3072 -N '' -f "${key_file}"
        else
            env "${nss_env[@]}" ssh-keygen -q -t ed25519 -N '' -f "${key_file}"
        fi
    fi
    chmod 600 "${key_file}"
done

sshd_config="${identity_dir}/sshd_config"
printf '%s\n' \
    'Port 2222' \
    'PidFile none' \
    'UsePAM no' \
    'PasswordAuthentication yes' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin no' \
    'PubkeyAuthentication yes' \
    'AuthorizedKeysFile .ssh/authorized_keys' \
    'StrictModes no' \
    'AllowTcpForwarding yes' \
    'X11Forwarding yes' \
    'Subsystem sftp internal-sftp' \
    "AllowUsers ${LDAP_USER}" \
    "HostKey ${sshd_dir}/ssh_host_ed25519_key" \
    "HostKey ${sshd_dir}/ssh_host_rsa_key" > "${sshd_config}"

env "${nss_env[@]}" /usr/sbin/sshd -t -f "${sshd_config}"

# Run sshd as the runtime identity; it only ever serves that one account.
env "${nss_env[@]}" /usr/sbin/sshd -D -e -f "${sshd_config}" &
sshd_pid=$!

if [ $# -eq 0 ]; then
    set -- /bin/bash
fi

"$@" &
workload_pid=$!

# Keep the container alive while both processes are healthy.
if wait -n -p finished_pid "${sshd_pid}" "${workload_pid}"; then
    workload_status=0
else
    workload_status=$?
fi

# Stop the remaining process when either sshd or the workload exits.
if [[ "${finished_pid}" == "${sshd_pid}" ]]; then
    kill "${workload_pid}" 2>/dev/null || true
    wait "${workload_pid}" 2>/dev/null || true
else
    kill "${sshd_pid}" 2>/dev/null || true
    wait "${sshd_pid}" 2>/dev/null || true
fi
exit "${workload_status}"
