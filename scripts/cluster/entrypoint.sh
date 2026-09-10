#!/usr/bin/env bash

set -Eeuo pipefail

# Validate the runtime identity supplied by Run:ai.
: "${LDAP_USER:?LDAP_USER must be set by the workload submission}"
: "${LDAP_UID:?LDAP_UID must be set by the workload submission}"
: "${LDAP_GID:?LDAP_GID must be set by the workload submission}"
: "${SSH_PASSWORD:?SSH_PASSWORD must be set by the workload submission}"

if [[ ! "${LDAP_USER}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    printf '%s\n' 'LDAP_USER contains unsupported characters' >&2
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

mkdir -p \
    "${HOME}" \
    "${XDG_CONFIG_HOME}" \
    "${XDG_CACHE_HOME}" \
    "${XDG_DATA_HOME}" \
    "${XDG_STATE_HOME}" \
    "${UV_CACHE_DIR}" \
    "${UV_PYTHON_INSTALL_DIR}" \
    "${VSCODE_AGENT_FOLDER}"

# Create the runtime account and assign ownership of its HOME.
group_name="ldap-${LDAP_GID}"
getent group "${LDAP_GID}" >/dev/null || groupadd --gid "${LDAP_GID}" "${group_name}"
getent passwd "${LDAP_USER}" >/dev/null || useradd \
    --uid "${LDAP_UID}" \
    --gid "${LDAP_GID}" \
    --home-dir "${HOME}" \
    --shell /bin/bash \
    --no-create-home \
    "${LDAP_USER}"
chown -R "${LDAP_UID}:${LDAP_GID}" "${HOME}"

# Set SSH authentication and grant passwordless sudo.
printf '%s:%s\n' "${LDAP_USER}" "${SSH_PASSWORD}" | chpasswd
unset SSH_PASSWORD

sudoers_file=/etc/sudoers.d/ldap-user
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "${LDAP_USER}" > "${sudoers_file}"
chmod 440 "${sudoers_file}"
visudo -cf "${sudoers_file}" >/dev/null

# Generate persistent host keys and configure sshd.
sshd_config=/run/sshd/sshd_config
project_dir="${HOME%/home/*}"
if [[ -n "${project_dir}" && "${project_dir}" != "${HOME}" ]]; then
    host_key_dir="${project_dir}/.ssh-host-keys"
else
    host_key_dir=/run/sshd/host-keys
fi
mkdir -p /run/sshd
mkdir -p "${host_key_dir}"
chmod 700 "${host_key_dir}"
for key_type in ed25519 rsa; do
    key_file="${host_key_dir}/ssh_host_${key_type}_key"
    if [[ ! -s "${key_file}" ]]; then
        if [[ "${key_type}" == rsa ]]; then
            ssh-keygen -q -t rsa -b 3072 -N '' -f "${key_file}"
        else
            ssh-keygen -q -t ed25519 -N '' -f "${key_file}"
        fi
    fi
    chmod 600 "${key_file}"
done
printf '%s\n' \
    'Port 2222' \
    'UsePAM no' \
    'PasswordAuthentication yes' \
    'KbdInteractiveAuthentication no' \
    'PermitRootLogin no' \
    'PubkeyAuthentication yes' \
    'AllowTcpForwarding yes' \
    'X11Forwarding yes' \
    'Subsystem sftp internal-sftp' \
    "AllowUsers ${LDAP_USER}" \
    "HostKey ${host_key_dir}/ssh_host_ed25519_key" \
    "HostKey ${host_key_dir}/ssh_host_rsa_key" > "${sshd_config}"
sshd -t -f "${sshd_config}"

# Run sshd as root, but run the workload as the LDAP user.
/usr/sbin/sshd -D -f "${sshd_config}" &
sshd_pid=$!

if [ $# -eq 0 ]; then
    set -- /bin/bash
fi

runuser --preserve-environment --user "${LDAP_USER}" -- "$@" &
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
