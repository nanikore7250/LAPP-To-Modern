output "app_url" {
  description = "アプリのURL (HTTPS)"
  value       = "https://${var.domain_name}"
}

output "route53_nameservers" {
  description = "お名前.comのネームサーバー設定に使用するNSレコード"
  value       = aws_route53_zone.main.name_servers
}

output "rds_endpoint" {
  description = "RDS endpoint (private, accessible from EC2 only)"
  value       = aws_db_instance.postgres.address
}
