variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "db_name" {
  description = "Aurora database name"
  type        = string
  default     = "eventsdb"
}

variable "db_user" {
  description = "Aurora master username"
  type        = string
  default     = "events_user"
}

variable "docker_image" {
  description = "Docker image tag to deploy"
  type        = string
  default     = "latest"
}
