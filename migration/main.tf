# ─── migration/main.tf ───────────────────────────────────────────────────
# ECS Fargate + Aurora Serverless + ALB
# Referência para o projeto de migração citado no contexto da entrevista.
# Separado da implementação atual (EC2 + RDS) para demonstrar o plano.
#
# Para aplicar:
#   1. Copiar modules/ e variations/ para o terraform/
#   2. Ajustar variáveis de ambiente
#   3. terraform plan -var-file=migration.tfvars

data "aws_vpc" "main" {
  tags = { Name = "events-app-vpc" }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { Name = "events-app-public*" }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { Name = "events-app-private*" }
}

data "aws_sqs_queue" "events" {
  name = "events-queue"
}

data "aws_ecr_repository" "app" {
  name = "events-app"
}

# ── ALB ─────────────────────────────────────────────────────────────────

resource "aws_lb" "app" {
  name               = "events-app-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.public.ids
}

resource "aws_lb_target_group" "app" {
  name        = "events-app-tg"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_security_group" "alb" {
  name        = "events-app-alb"
  description = "ALB: HTTP from internet"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs" {
  name        = "events-app-ecs"
  description = "ECS: allow from ALB"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── ECS Fargate ─────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "app" {
  name = "events-app"
}

resource "aws_ecs_task_definition" "app" {
  family                   = "events-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "api"
    image     = "${data.aws_ecr_repository.app.repository_url}:latest"
    essential = true
    portMappings = [
      { containerPort = 8000, protocol = "tcp" },
      { containerPort = 5000, protocol = "tcp" },
    ]
    environment = [
      { name = "SQS_QUEUE_URL", value = data.aws_sqs_queue.events.id },
      { name = "DB_HOST",       value = aws_rds_cluster.aurora.endpoint },
      { name = "DB_NAME",       value = var.db_name },
      { name = "DB_USER",       value = var.db_user },
      { name = "DB_PASSWORD",   value = random_password.db.result },
      { name = "AWS_REGION",    value = var.aws_region },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = "events-app"
  cluster         = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = data.aws_subnets.private.ids
    security_groups = [aws_security_group.ecs.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "api"
    container_port   = 8000
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}

# ── IAM ECS ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "ecs_execution" {
  name = "events-app-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name = "events-app-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task_sqs" {
  name = "events-app-ecs-task-sqs"
  role = aws_iam_role.ecs_task.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueUrl",
      ]
      Resource = data.aws_sqs_queue.events.arn
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task_secrets" {
  name = "events-app-ecs-task-secrets"
  role = aws_iam_role.ecs_task.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = data.aws_secretsmanager_secret.db_password.arn
    }]
  })
}

data "aws_secretsmanager_secret" "db_password" {
  name = "events-app/db-password"
}

# ── Aurora Serverless ───────────────────────────────────────────────────

resource "aws_rds_cluster" "aurora" {
  cluster_identifier  = "events-app-aurora"
  engine              = "aurora-postgresql"
  engine_mode         = "provisioned"
  engine_version      = "16.4"
  database_name       = var.db_name
  master_username     = var.db_user
  master_password     = random_password.db.result
  port                = 5432
  db_subnet_group_name = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]
  skip_final_snapshot = true
  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 2
  }
}

resource "aws_rds_cluster_instance" "aurora" {
  count              = 1
  identifier         = "events-app-aurora-${count.index}"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
}

resource "aws_db_subnet_group" "aurora" {
  name       = "events-app-aurora"
  subnet_ids = data.aws_subnets.private.ids
}

resource "aws_security_group" "aurora" {
  name        = "events-app-aurora"
  description = "Aurora: PostgreSQL from ECS"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }
}

# ── CloudWatch Logs ─────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/events-app"
  retention_in_days = 7
}

# ── Deploy Rolling com downtime ≤ 5 min ──────────────────────────────────
#
# O ECS Service está configurado com:
#   deployment_minimum_healthy_percent = 100   → mantém 100% das tasks durante deploy
#   deployment_maximum_percent         = 200   → sobe 100% novas antes de matar as antigas
#   deployment_circuit_breaker {
#     enable   = true                          → se novo deploy falhar, reverte sozinho
#     rollback = true
#   }
#
# Isso garante:
#   - Zero downtime durante deploy (rolling com 2 tasks)
#   - Rollback automático se health check falhar
#   - Janela de 5 minutos respeitada
#
# GitHub Actions (deploy.yml):
#   - aws ecs update-service --cluster events-app --service events-app \
#     --force-new-deployment
