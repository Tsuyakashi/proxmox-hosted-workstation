set -e
: "${VAULT_ADDR:?set VAULT_ADDR before running (e.g. http://192.168.100.200:8200)}"

if ! vault secrets list -format=json | grep -q '"pve-workstation/"'; then
    vault secrets enable -path=pve-workstation -version=2 kv
else
    echo "exist, skipping"
fi


vault policy write oci-proxmox-node - <<POLICY
path "pve-workstation/data/api" {
  capabilities = ["create", "read", "update"]
}
path "pve-workstation/metadata/api" {
  capabilities = ["read", "list"]
}
POLICY
