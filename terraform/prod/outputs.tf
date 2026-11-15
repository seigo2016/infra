output "data_store_ip" {
  description = "IP address of the data-store (Garage S3) VM"
  value       = module.data_store.ip
}

output "research_ops_cp_ip" {
  description = "IP address of the research-ops Control Plane VM"
  value       = module.research_ops_cp.ip
}

output "research_ops_cp_restore_test_ip" {
  description = "IP address of the research-ops-cp restore rehearsal VM, or null when it is not created"
  value       = one(module.research_ops_cp_restore_test[*].ip)
}
