# ZANSIN Cybersecurity Training Environment
# Creates 2 Ubuntu VMs for ZANSIN training platform

terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.1-rc9"
    }
  }
}

# ZANSIN Control Server VM
resource "proxmox_vm_qemu" "zansin_control" {
  name        = var.control_vm_name
  target_node = var.proxmox_node
  clone       = var.template_vm_base
  full_clone  = true
  os_type     = "cloud-init"

  cpu {
    cores   = var.vm_cores
    sockets = 1
  }

  memory  = var.vm_memory
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

  # Network Configuration
  network {
    id     = 0
    model  = "virtio"
    bridge = var.network_bridge
  }

  ciuser       = var.ssh_user
  cipassword   = var.ssh_password
  sshkeys      = var.ssh_public_key
  ipconfig0    = "ip=${var.control_ip}/${var.network_prefix},gw=${var.gateway}"

}

# ZANSIN Training Server VM
resource "proxmox_vm_qemu" "zansin_training" {
  name        = var.training_vm_name
  target_node = var.proxmox_node
  clone       = var.template_vm_base
  full_clone  = true
  os_type     = "cloud-init"

  cpu {
    cores   = var.vm_cores
    sockets = 1
  }


  memory  = var.vm_memory
  agent    = 1
  onboot   = true
  scsihw   = "virtio-scsi-pci"
  bootdisk = "scsi0"

  # Disks: attach OS disk at scsi0 and cloud-init at ide2
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

  # Network Configuration
  network {
    id     = 0
    model  = "virtio"
    bridge = var.network_bridge
  }

  ciuser       = var.ssh_user
  cipassword   = var.ssh_password
  sshkeys      = var.ssh_public_key
  ipconfig0    = "ip=${var.training_ip}/${var.network_prefix},gw=${var.gateway}"

}
