# Standalone VM module - one cloud-init clone with a static IP on one bridge.
# Generic counterpart of modules/data-store: every site-specific value (node,
# storage pool, bridge, template, IP) comes from the caller, so the same
# definition can be applied to another Proxmox host by changing variables only.

terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.2-rc10"
    }
  }
}

resource "proxmox_vm_qemu" "vm" {
  # The template is used when creating a VM, not to update an existing one.
  lifecycle {
    ignore_changes = [clone]
  }

  name        = var.vm_name
  description = var.description
  target_node = var.proxmox_node
  clone       = var.template_vm_base
  full_clone  = true
  os_type     = "cloud-init"

  cpu {
    cores   = var.cores
    sockets = var.sockets
  }

  memory             = var.memory
  agent              = 1
  start_at_node_boot = var.start_at_node_boot
  scsihw             = "virtio-scsi-pci"
  boot               = "order=scsi0"
  power_state        = "running"
  # These VMs hold databases: reboot them by hand, not in the middle of an apply.
  automatic_reboot = false

  startup_shutdown {
    order            = -1
    startup_delay    = -1
    shutdown_timeout = -1
  }

  disks {
    scsi {
      scsi0 {
        disk {
          size       = var.disk_size
          storage    = var.storage_pool
          emulatessd = true
          discard    = true
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = var.storage_pool
        }
      }
    }
  }

  serial {
    id   = 0
    type = "socket"
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = var.network_bridge
  }

  sshkeys   = var.ssh_public_key
  ipconfig0 = "ip=${var.ip_address}/${var.network_prefix},gw=${var.gateway}"
}
