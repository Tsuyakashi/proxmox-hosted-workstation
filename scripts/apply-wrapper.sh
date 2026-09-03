#!/bin/bash

if (return 0 2>/dev/null); then
    _tfv_sourced=1
else
    _tfv_sourced=0
fi

_tfv_fetch_secrets() {
    local -
    set -u
    set -o pipefail

    : "${VAULT_ADDR:=http://192.168.100.200:8200}"
    export VAULT_ADDR

    if ! command -v vault &>/dev/null; then
        echo "error: vault CLI not found in PATH" >&2
        return 1
    fi

    if ! vault token lookup &>/dev/null; then
        echo "error: no valid Vault token — run 'vault login -method=userpass username=<you>' first" >&2
        return 1
    fi

    echo "Fetching secrets from Vault (${VAULT_ADDR})..." >&2

    TF_VAR_proxmox_root_password="$(vault kv get -field=pve-root-pass pve-workstation/api)" || return 1
    export TF_VAR_proxmox_root_password

    TF_VAR_proxmox_api_token="$(vault kv get -field=api_token proxmox/terraform-provider)" || return 1
    export TF_VAR_proxmox_api_token

    AWS_ACCESS_KEY_ID="$(vault kv get -field=access_key proxmox/minio-credentials)" || return 1
    AWS_SECRET_ACCESS_KEY="$(vault kv get -field=secret_key proxmox/minio-credentials)" || return 1
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY

    return 0
}

if [ "${_tfv_sourced}" -eq 1 ]; then
    terraform() {
        if [ -f "./variables.tf" ] && grep -q "proxmox_api_token" ./variables.tf 2>/dev/null; then
            if [ -z "${TF_VAR_proxmox_api_token:-}" ]; then
                _tfv_fetch_secrets || return $?
            fi
        fi
        command terraform "$@"
    }
else
    set -euo pipefail
    if [ "$#" -eq 0 ]; then
        echo "usage: $(basename "$0") <terraform-subcommand> [args...]" >&2
        exit 1
    fi
    _tfv_fetch_secrets || exit $?
    exec terraform "$@"
fi
