output "instance_public_ip" {
  description = "IP Público da instância criada na OCI"
  value       = oci_core_instance.ubuntu_instance.public_ip
}
