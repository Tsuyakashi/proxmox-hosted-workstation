terraform {
  backend "s3" {
    bucket       = "proxmox-hosted-workstation-tfstate"
    key          = "windows/terraform.tfstate"
    region       = "auto"
    use_lockfile = true

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_region_validation      = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}
