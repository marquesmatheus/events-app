# Migration: EC2 → ECS Fargate + Aurora

Este diretório contém a referência para a migração mencionada no contexto da entrevista.

**Não faz parte da implementação atual (EC2 + RDS).** É um plano executável separado.

---

## O que muda

| Hoje (EC2) | Amanhã (Fargate) | Motivo |
|---|---|---|
| EC2 t2.micro | ECS Fargate (256/512) | Sem OS p/ gerenciar, escala automática |
| RDS db.t3.micro | Aurora Serverless v2 | Escala de 0.5 a 2 ACU, paga por uso |
| Elastic IP | ALB (Application Load Balancer) | DNS gerenciado, health checks, rollback |
| Deploy via SSM | ECS rolling update | Downtime zero, circuit breaker automático |
| 1 container (3 serviços) | 2 containers (API + Worker separados) | Escala independente, isolamento |
| Frontend na EC2 | Frontend removido (Terraform local/GH Actions) | Segurança — UI de gestão não vai para produção |

## O que permanece

- **SQS Queue** (`events-queue`) — reutilizada
- **ECR Repository** (`events-app`) — reutilizado
- **Secrets Manager** (`events-app/db-password`) — reutilizado
- **VPC + Subnets** — reutilizadas (precisa adicionar mais 1 subnet privada em AZ diferente)

## Arquitetura Fargate

```
Internet ──▶ ALB (:80) ──▶ ECS Fargate (2 tasks, subnets privadas)
                               ├── API :8000 (FastAPI + Dashboard)
                               └── Worker (background)
                                    └── PostgreSQL (Aurora Serverless, subnet privada)
```

## Deploy zero downtime

```yaml
# .github/workflows/deploy.yml (job de deploy)
aws ecs update-service \
  --cluster events-app \
  --service events-app \
  --force-new-deployment \
  --region us-east-1

aws ecs wait services-stable \
  --cluster events-app \
  --services events-app \
  --region us-east-1
```

ECS gerencia o rolling: sobe tasks novas, valida health check `/health`, mata as antigas.
`circuit_breaker { enable = true, rollback = true }` reverte automaticamente se falhar.

## Custo estimado

| Recurso | Custo/mês |
|---|---|
| ECS Fargate (2 tasks, 256/512) | ~$18 |
| ALB | ~$22 |
| Aurora Serverless (0.5-2 ACU) | ~$15-30 |
| SQS | $0 (1M requests free) |
| ECR | $0.02 (imagem pequena) |
| **Total** | **~$55-70/mês** |

vs. ~$0/mês no free tier atual (primeiro ano).

## Como aplicar

```bash
# 1. Criar bucket S3 para state (bootstrap)
aws s3 mb s3://events-app-tfstate --region us-east-1

# 2. Copiar provider.tf para terraform/ (substitui o atual)
cp migration/provider.tf terraform/
cp migration/main.tf terraform/
cp migration/variables.tf terraform/
cp migration/outputs.tf terraform/

# 3. Aplicar
cd terraform
terraform init -migrate-state
terraform plan
terraform apply -auto-approve

# 4. Deploy da imagem
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password | docker login --username AWS --password-stdin \
  $ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
docker build -t $ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/events-app:latest \
  -f backend/Dockerfile .
docker push $ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/events-app:latest

# 5. Forçar deploy (ECS pega a nova imagem)
aws ecs update-service \
  --cluster events-app \
  --service events-app \
  --force-new-deployment
```
