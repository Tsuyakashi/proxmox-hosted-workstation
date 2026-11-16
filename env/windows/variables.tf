variable "proxmox_node" {
  type    = string
  default = "bare-pve"
}

variable "proxmox_api_token" {
  type      = string
  sensitive = true
}

variable "cores" {
  type    = number
  default = 4
}

variable "memory" {
  description = "MiB. Same as the Ubuntu CT: they never run at the same time."
  type        = number
  default     = 12288
}

variable "games_ssd_size" {
  description = "GiB, shared game disk on local-lvm (SSD). Grow only; then extend the volume in Windows."
  type        = number
  default     = 100
}

variable "games_hdd_size" {
  description = "GiB, shared game disk on the hdd thin pool (sdb). Grow only."
  type        = number
  default     = 200
}

variable "protection" {
  description = "Proxmox protection flag on the VM. Clear it deliberately before any destroy/replace."
  type        = bool
  default     = true
}

variable "iso_file_id" {
  description = "Installer ISO in the CD drive; null = no CD drive."
  type        = string
  default     = "none"
}

variable "gpu_primary" {
  description = "x-vga on the card (output to the monitor). false only until Windows + the NVIDIA driver are installed."
  type        = bool
  default     = true
}

variable "agent_enabled" {
  description = "QEMU guest agent channel. true only after the virtio guest tools are installed in Windows."
  type        = bool
  default     = false
}
