output "ec2_public_ip" {
  description = "EC2 public IP (API endpoint)"
  value       = aws_eip.app.public_ip
}

output "api_url" {
  description = "API base URL"
  value       = "http://${aws_eip.app.public_ip}:8080"
}

output "sqs_queue_url" {
  description = "SQS queue URL"
  value       = aws_sqs_queue.events.id
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = aws_db_instance.postgres.address
}

output "ecr_repository_url" {
  description = "ECR repository URL"
  value       = aws_ecr_repository.app.repository_url
}

output "db_secret_arn" {
  description = "ARN do segredo no Secrets Manager (DB password)"
  value       = aws_secretsmanager_secret.db_password.arn
}
