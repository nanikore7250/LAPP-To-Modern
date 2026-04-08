output "alb_dns_name" {
  description = "ALB DNS name — open this URL in a browser to reach the app"
  value       = "http://${aws_lb.alb.dns_name}"
}

output "rds_endpoint" {
  description = "RDS endpoint (private, accessible from EC2 only)"
  value       = aws_db_instance.postgres.address
}
