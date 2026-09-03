variable "name" {
  type = string
}

variable "node_name" {
  type = string
}

variable "cores" {
  type    = number
  default = 1
}

variable "memory" {
  type    = number
  default = 512
}

variable "gpu_name" {
  type    = string
  default = "gtx950"
}

variable "datastore_id_disk" {
  description = "Datastore для диска VM."
  type        = string
  default     = "local-lvm"
}

variable "disk_interface" {
  description = "sata for win scsi0 for linux"
  type        = string
  default     = "sata0"
}

variable "disk_size" {
  type    = number
  default = 10
}

variable "iso_file_id" {
  description = "File ID of an already-uploaded ISO, e.g. local:iso/Win10_22H2_Russian_x64v1.iso"
  type        = string
  default     = "ide3"
}

variable "boot_order" {
  type    = list(string)
  default = ["ide3", "sata0"]
}

variable "network_bridge" {
  type    = string
  default = "vmbr0"
}

variable "mac" {
  type    = string
  default = "aa:bb:cc:dd:ee:ff"
}

variable "network_model" {
  type    = string
  default = "e1000"
}

variable "gpu_devices" {
  description = "List of PCI devices to map: path, id, iommu_group, subsystem_id"
  type = list(object({
    path         = string
    id           = string
    iommu_group  = number
    subsystem_id = string
  }))
  default = []
}

variable "os_type" {
  description = "l26 - linux, win10 - windows"
  type        = string
  default     = "win10"
}