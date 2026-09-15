# macOS Tahoe desktop workstation on bare-pve -- third mutually-exclusive
# mode alongside env/windows and env/ubuntu, arbitrated by the same
# scripts/gpu-arbiter.sh (3-way as of this env). Real GPU passthrough (GTX
# 950 + USB + onboard audio, vfio-pci) -- NOT the headless macos-tahoe-headless
# env (different node, no GPU at all, unrelated).
#
# Consumes the SAME cluster hardware_mapping_pci entries env/windows already
# owns (manage_mappings = false) -- one GPU, one set of mappings, never two
# concurrent owners. Whole-workstation passthrough identical to env/windows'
# own device list.
#
# No kvm_arguments here on purpose: `args:` is root@pam-only (see
# mod/vm-headless's own discovery of this in macos-tahoe-headless) and the
# same Tahoe build booted and ran fine on cpu.type="host" alone before any
# args were ever applied there -- adding isa-applesmc later is what actually
# introduced a real bug (SMCWDT reboot hang, see that env's README). Add
# kvm_arguments back only if something concrete needs it, not preemptively.

module "macos_desktop" {
  source    = "../../mod/vm"
  name      = var.vm_name
  node_name = var.proxmox_node

  cores  = var.cores
  memory = var.memory
  mac    = var.mac

  network_model = "vmxnet3" # AppleVMXNet3Ethernet.kext ships built into every
  # macOS *including* the trimmed Recovery kernel collection (it's Apple's own
  # officially-supported VMware-guest driver) -- no OpenCore kext injection
  # needed at all. e1000/e1000e both left Recovery's `ifconfig -a` completely
  # empty (no en0, not even after injecting IntelMausiEthernet.kext), which
  # blocked startosinstall's apple.com clock-verification and swscan catalog
  # fetch. OSX-KVM's own OpenCore-Boot.sh explicitly notes vmxnet3 for High
  # Sierra installs for exactly this reason.
  os_type       = "l26"    # no macOS ostype in Proxmox; "Linux" is LongQT-sea's explicit pick

  disk_interface = "sata0"
  disk_size      = var.disk_size

  cdrom_interface = "ide0" # OpenCore boot ISO -- every boot, not just install
  iso_file_id     = var.opencore_iso_file_id

  installer_interface     = "sata1"
  installer_image_file_id = var.installer_image_file_id

  # Manual start only -- the arbiter's pre-start hook (once wired, see
  # README) does the actual GPU/USB rebind; on_boot=false matches
  # env/windows/env/ubuntu (no autostart race on node boot).
  on_boot = false

  manage_mappings = false
  passthrough = [
    {
      name        = "gtx950"
      primary_gpu = var.gpu_primary
      # See variables.tf's gpu_rom_file docstring -- null (default) leaves
      # rombar=1 against the card's own stock legacy-only VBIOS, same as
      # env/windows/env/ubuntu. Unlike those two, macOS never sees the
      # device at all in that mode (confirmed via ioreg's ACPI PCI tree,
      # not just "no picture") -- set gpu_rom_file once a real UEFI-GOP
      # dump for 10de:1402 is on the node.
      rom_file = var.gpu_rom_file
    },
    { name = "usb-xhci" },
    { name = "usb-ehci1" },
    { name = "usb-ehci2" },
    { name = "onboard-audio" },
  ]
}
