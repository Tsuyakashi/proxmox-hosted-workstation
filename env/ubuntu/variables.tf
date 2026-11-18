variable "proxmox_node" {
  type    = string
  default = "bare-pve"
}

variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "ssh_public_keys" {
  description = "root authorized_keys in the CT (tf-secrets: proxmox/ssh-keys)."
  type        = list(string)
  default     = []
}

variable "template_file_id" {
  description = "Minimal rootfs, not a cloud image: pveam download local ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
  type        = string
  default     = "local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
}

variable "cores" {
  type    = number
  default = 4
}

variable "memory" {
  description = "MiB. Same as the Windows VM: they never run at the same time."
  type        = number
  default     = 12288
}

variable "disk_size" {
  description = "rootfs GiB: desktop + NVIDIA userspace + apps + Proton prefixes (compatdata stays on ext4). Games go to the shared disks."
  type        = number
  default     = 64
}
