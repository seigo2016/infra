# Kubernetes module - VM resources for K8s cluster

terraform {
  required_providers {
    proxmox = {
      source  = "Telmate/proxmox"
      version = "3.0.2-rc10"
    }
  }
}

# Master node
resource "proxmox_vm_qemu" "k8s_master" {
  # The template is used when creating a VM, not to update an existing one.
  lifecycle {
    ignore_changes = [clone]
  }

  name        = var.master_name
  target_node = var.proxmox_node
  clone       = var.template_vm_base
  full_clone  = true
  os_type     = "cloud-init"

  cpu {
    cores   = var.master_cores
    sockets = var.master_sockets
  }

  memory             = var.master_memory
  agent              = 1
  start_at_node_boot = true
  scsihw             = "virtio-scsi-pci"
  boot               = "order=scsi0"
  power_state        = "running"

  startup_shutdown {
    order            = -1
    startup_delay    = -1
    shutdown_timeout = -1
  }

  disks {
    scsi {
      scsi0 {
        disk {
          size       = var.master_disk_size
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
  ipconfig0 = "ip=${var.master_ip}/${var.network_prefix},gw=${var.gateway}"
}

# Worker nodes
resource "proxmox_vm_qemu" "k8s_worker" {
  # The template is used when creating a VM, not to update an existing one.
  lifecycle {
    ignore_changes = [clone]
  }

  count       = length(var.worker_ips)
  name        = "${var.worker_name_prefix}-${count.index + 1}"
  target_node = var.proxmox_node
  clone       = var.template_vm_base
  full_clone  = true
  os_type     = "cloud-init"

  cpu {
    cores   = var.worker_cores
    sockets = var.worker_sockets
  }

  memory             = var.worker_memory
  agent              = 1
  start_at_node_boot = true
  scsihw             = "virtio-scsi-pci"
  boot               = "order=scsi0"
  power_state        = "running"

  startup_shutdown {
    order            = -1
    startup_delay    = -1
    shutdown_timeout = -1
  }

  disks {
    scsi {
      scsi0 {
        disk {
          size       = var.worker_disk_size
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
  ipconfig0 = "ip=${var.worker_ips[count.index]}/${var.network_prefix},gw=${var.gateway}"
}
