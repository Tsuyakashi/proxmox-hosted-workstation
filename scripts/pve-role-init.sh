#!/bin/bash
#
# scripts/pve-role-init.sh  (proxmox-hosted-workstation)
#
# Run ON any Proxmox node, as root (roles are cluster-wide, /etc/pve/user.cfg):
#
#   ssh root@bare-pve 'bash -s' < scripts/pve-role-init.sh
#   ssh root@bare-pve 'DRY_RUN=1 bash -s' < scripts/pve-role-init.sh   # show the diff only
#
# (`ssh 'bash -s' < script` does NOT forward the local environment — put
# overrides like DRY_RUN / ROLE inside the remote command string, as above.)
#
# Makes sure the shared Terraform role has every privilege THIS repo needs,
# without touching anything else in it:
#   1. reads the role's current privileges,
#   2. adds the ones from REQUIRED_PRIVS that are missing,
#   3. writes the merged set back — only if something was missing.
# Idempotent: a second run is a no-op. Never removes a privilege — the role
# is shared with iac-proxmox-lab / valheim-lxc / k8s-lab / lombel-landing,
# whose needs are not listed here.
#
# The role and the terraform@pve token/ACL are owned by iac-proxmox-lab;
# this script refuses to create the role, only extends it.
#
# NOTE: Sys.Modify is only effective where the token's ACL grants this role.
# Creating a privileged CT checks it on `/` exactly — verify with
#   pveum acl list | grep -i terraform
# that the role is assigned on `/` (propagate=1), not only on /vms or /storage.

set -euo pipefail

ROLE="${ROLE:-TerraformProv}"
DRY_RUN="${DRY_RUN:-}"

# What mod/ct + mod/vm + env/ubuntu + env/windows actually call, and why.
REQUIRED_PRIVS=(
    VM.Allocate                # create / destroy the CT and the Windows VM
    VM.Audit                   # read CT/VM config and status on refresh
    VM.PowerMgmt               # started / shutdown on destroy
    VM.Config.Disk             # rootfs (CT), sata0 + EFI disk (VM)
    VM.Config.CDROM            # Windows installer ISO slot
    VM.Config.CPU              # cpu {}
    VM.Config.Memory           # memory {}
    VM.Config.Network          # network_interface {} / network_device {}
    VM.Config.Options          # hostname, tags, start_on_boot/on_boot, dns
    VM.Config.HWType           # q35, ovmf, serial_device, hostpci
    Datastore.Audit            # read template / ISO volumes
    Datastore.AllocateSpace    # allocate rootfs / VM disks on local-lvm
    Mapping.Audit              # read cluster PCI hardware mappings on refresh
    Mapping.Modify             # env/windows owns proxmox_hardware_mapping_pci
    Mapping.Use                # attach mappings as hostpciN
    SDN.Use                    # attach the NIC to vmbr0 (/sdn/zones/localnetwork/vmbr0)
    Sys.Modify                 # env/ubuntu: create a PRIVILEGED CT (unprivileged=0) —
                               # pve-container checks Sys.Modify on `/`, no narrower path.
                               # Lets `terraform apply` create it directly — no node-side
                               # `pct create` + `terraform import` round-trip.
)

log() { echo "=== $* ===" >&2; }

command -v pvesh >/dev/null || { echo "error: pvesh not found — run this on a Proxmox node" >&2; exit 1; }

# --- 1. current privileges ---------------------------------------------------
if ! current_json="$(pvesh get "/access/roles/${ROLE}" --output-format json 2>/dev/null)"; then
    echo "error: role '${ROLE}' does not exist — it is created by iac-proxmox-lab, not here" >&2
    exit 1
fi

mapfile -t current < <(python3 -c '
import json, sys
for k, v in sorted(json.load(sys.stdin).items()):
    if v:
        print(k)
' <<<"$current_json")

mapfile -t known < <(pveum role list --output-format json | python3 -c '
import json, sys
s = set()
for r in json.load(sys.stdin):
    s.update(p for p in r.get("privs", "").split(",") if p)
print("\n".join(sorted(s)))
')

# --- 2. compute what is missing -----------------------------------------------
declare -A have=() exists=()
for p in "${current[@]}"; do have["$p"]=1; done
for p in "${known[@]}"; do exists["$p"]=1; done

missing=()
for p in "${REQUIRED_PRIVS[@]}"; do
    if [ -z "${exists[$p]:-}" ]; then
        echo "error: privilege '${p}' is unknown to this PVE ($(pveversion | cut -d/ -f2)) — fix REQUIRED_PRIVS" >&2
        exit 1
    fi
    [ -n "${have[$p]:-}" ] || missing+=("$p")
done

log "role ${ROLE}: ${#current[@]} privileges, ${#REQUIRED_PRIVS[@]} required by proxmox-hosted-workstation"

if [ "${#missing[@]}" -eq 0 ]; then
    echo "  nothing to do — all required privileges already present"
    exit 0
fi

printf '  + %s\n' "${missing[@]}"

if [ -n "$DRY_RUN" ]; then
    echo "  DRY_RUN set — not applying"
    exit 0
fi

# --- 3. apply the merged set ---------------------------------------------------
merged="$(printf '%s\n' "${current[@]}" "${missing[@]}" | sort -u | paste -sd, -)"
pvesh set "/access/roles/${ROLE}" --privs "$merged"

after="$(pvesh get "/access/roles/${ROLE}" --output-format json)"
for p in "${REQUIRED_PRIVS[@]}"; do
    python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]).get(sys.argv[2]) else 1)' "$after" "$p" \
        || { echo "error: '${p}' still missing after update" >&2; exit 1; }
done

log "done: added ${#missing[@]} privilege(s) to ${ROLE}"
