# Hermes Agent module - standalone VM for NousResearch/hermes-agent

terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.1-rc9"
    }
  }
}

resource "proxmox_vm_qemu" "hermes_agent" {
  name        = var.vm_name
  target_node = var.proxmox_node
  clone       = var.template_vm_base
  full_clone  = true
  os_type     = "cloud-init"

  cpu {
    cores   = var.cores
    sockets = var.sockets
  }

  memory   = var.memory
  agent    = 1
  onboot   = true
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  disks {
    scsi {
      scsi0 {
        disk {
          size       = var.disk_size
          storage    = var.storage_pool
          emulatessd = true
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
