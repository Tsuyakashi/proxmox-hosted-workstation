module "nodes" {
  source = "git::https://github.com/Tsuyakashi/iac-proxmox-lab.git//modules/pve-nodes?ref=modules/v0.2.0"
  node   = var.proxmox_node
}

# API token only; no SSH block: nothing here uploads snippets.
provider "proxmox" {
  endpoint  = module.nodes.endpoint
  api_token = var.proxmox_api_token
}
