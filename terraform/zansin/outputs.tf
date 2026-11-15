output "control_server_info" {
  description = "Control server information"
  value = {
    name = module.zansin_environment.control_vm_name
    id   = module.zansin_environment.control_vm_id
    ip   = module.zansin_environment.control_ip
  }
}

output "training_server_info" {
  description = "Training server information"
  value = {
    name = module.zansin_environment.training_vm_name
    id   = module.zansin_environment.training_vm_id
    ip   = module.zansin_environment.training_ip
  }
}

output "ssh_connection_info" {
  description = "SSH connection information"
  value = {
    user             = module.zansin_environment.ssh_user
    control_command  = "ssh ${module.zansin_environment.ssh_user}@${module.zansin_environment.control_ip}"
    training_command = "ssh ${module.zansin_environment.ssh_user}@${module.zansin_environment.training_ip}"
  }
}

output "setup_instructions" {
  description = "Post-deployment instructions"
  value       = <<-EOT
    ZANSIN Environment Successfully Deployed!

    Control Server:  ${module.zansin_environment.control_ip}
    Training Server: ${module.zansin_environment.training_ip}
    SSH User:        ${module.zansin_environment.ssh_user}

    Connect to control server:
    ssh ${module.zansin_environment.ssh_user}@${module.zansin_environment.control_ip}

    ZANSIN files location:
    /home/${module.zansin_environment.ssh_user}/ZANSIN/

    Start training exercises:
    cd ~/ZANSIN && ls documents/
  EOT
}
