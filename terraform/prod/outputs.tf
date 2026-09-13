output "data_store_ip" {
  description = "IP address of the data-store (Garage S3) VM"
  value       = module.data_store.ip
}
