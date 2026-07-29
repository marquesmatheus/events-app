output "alb_dns" {
  description = "ALB DNS name (API endpoint)"
  value       = aws_lb.app.dns_name
}

output "ecs_cluster" {
  description = "ECS Cluster name"
  value       = aws_ecs_cluster.app.name
}

output "ecs_service" {
  description = "ECS Service name"
  value       = aws_ecs_service.app.name
}

output "aurora_endpoint" {
  description = "Aurora cluster endpoint"
  value       = aws_rds_cluster.aurora.endpoint
}
