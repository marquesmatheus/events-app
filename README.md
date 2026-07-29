# events-app

```
POST /events → SQS → Worker → PostgreSQL
```

Infraestrutura AWS em **Terraform + Docker + GitHub Actions**.
Todo o stack cabe no free tier (`t2.micro` + `db.t3.micro`) — **~$0/mês no primeiro ano**.

Dois pushs e a prova de conceito está no ar. Um comando e tudo some sem custo residual.

> 📸 **Evidências do funcionamento** → [`evidencias/`](./evidencias/) (prints do dashboard, worker logs, RDS queries)

---

## Sumário

1. [Arquitetura](#1-arquitetura)
2. [O que eu decidi e o que abri mão](#2-o-que-eu-decidi-e-o-que-abri-mão)
3. [Como uma versão quebrada não chega em produção](#3-como-uma-versão-quebrada-não-chega-em-produção)
4. [Como isso vira 4 ambientes (dev / prod)](#4-como-isso-vira-4-ambientes-dev--prod)
5. [Setup rápido](#5-setup-rápido)
6. [Cleanup — custo zero](#6-cleanup--custo-zero)
7. [Segurança](#7-segurança)
8. [IAM Permissions para o CI](#8-iam-permissions-para-o-ci)
10. [Resumo do que foi feito](#10-resumo-do-que-foi-feito)

---

## 1. Arquitetura

```
┌─────────────┐     ┌──────────┐     ┌──────────────┐     ┌──────────┐
│  Cliente     │────▶│ FastAPI  │────▶│  SQS Queue   │────▶│  Worker  │
│ POST /events │     │ :8080    │     │  (pública)   │     │ :8000    │
└─────────────┘     └──────────┘     └──────────────┘     └────┬─────┘
                          │                                      │
                    ┌─────▼──────┐                      ┌───────▼──────┐
                    │  Dashboard │                      │  PostgreSQL  │
                    │  GET /     │                      │  (privado)   │
                    └────────────┘                      └──────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  EC2 (t2.micro) — Docker Container                                  │
│  ├── FastAPI :8000 → Host :8080  (API + Dashboard)                  │
│  └── Worker (background)         (SQS consumer → PostgreSQL)        │
├─────────────────────────────────────────────────────────────────────┤
│  VPC: 10.0.0.0/16                                                    │
│  ├── Subnet Pública  (10.0.1.0/24) → EC2 + Internet Gateway         │
│  └── Subnet Privada (10.0.2.0/24) → RDS (sem acesso internet)       │
├─────────────────────────────────────────────────────────────────────┤
│  Secrets Manager → random_password (24 chars, recovery_window = 0)  │
│  ECR → events-app (force_delete = true)                             │
│  SSM → deploy sem SSH, zero portas administrativas abertas          │
└─────────────────────────────────────────────────────────────────────┘
```

**Recursos AWS criados:** VPC (2 subnets), Internet Gateway, 2 route tables, 2 Security Groups, SQS Queue, ECR Repository, IAM Role (3 policies), EC2 Instance, Elastic IP, RDS PostgreSQL, Secrets Manager Secret, RDS Subnet Group.

> ⚠️ **Ausências propositais:** sem ALB (acesso direto via Elastic IP), sem multi-AZ (1 AZ apenas),
> sem NAT Gateway. São cortes de custo — detalhados na tabela abaixo.

---

## 2. O que eu decidi e o que abri mão

Cada escolha aqui é um trade-off consciente entre custo, simplicidade e segurança.

### Decisões técnicas

| Decisão | Justificativa | Trade-off |
|---|---|---|
| **1 AZ (sem multi-AZ)** | RDS free tier é single-AZ. EC2 também em 1 AZ. Custo: multi-AZ RDS dobra o custo (2x db.t3.micro). | Se a AZ cair, tudo fica fora. Recovery manual: alterar SG/EIP para apontar para nova AZ. |
| **Sem ALB** | ElasticIP direto na EC2. ALB custa ~$22/mês mesmo sem tráfego. Para 1 instância não faz sentido. | Sem health check automático, sem balanceamento, sem blue/green. Downtime durante deploy. |
| **EC2 (não Fargate)** | Free tier dá 750h/mês de EC2. Fargate custa ~$10/mês mesmo parado. | Precisa gerenciar OS (atualizações, patches). |
| **SSM (não SSH)** | Zero portas administrativas abertas. Deploy via SSM funciona sem key pair. | Depende do SSM Agent (já vem no Ubuntu). Primeiro deploy precisa esperar o registro. |
| **Sem NAT Gateway** | Economia de ~$35/mês. Subnet privada não precisa de internet — RDS só fala com EC2. | Sem internet na subnet privada. Para acessar SQS, a EC2 está na subnet pública. |
| **Sem VPC Endpoints** | SQS é acessado via Internet Gateway. VPC Endpoint custa ~$7/mês. | Tráfego SQS passa pela internet (dentro da AWS, seguro por TLS). |
| **Secrets Manager** | Password gerado por `random_password`, armazenado no Secrets Manager, nunca em texto plano. `recovery_window_in_days = 0` para exclusão imediata. | Custo de $0,40/mês pelo secret. |
| **1 container (3 serviços)** | Simplifica deploy e gerenciamento. Um único `docker run` sobe API + Frontend + Worker. | Serviços acoplados. Se o worker falha, o container restarta tudo. |
| **`force_delete = true` no ECR** | Garante que `terraform destroy` apague o repositório mesmo com imagens. | Perde histórico de imagens no destroy. |
| **`skip_final_snapshot = true` no RDS** | Evita snapshot residual pós-destroy. | Sem backup de desativação. |
| **IAM Instance Profile (não Access Key)** | EC2 assume role automaticamente. Sem credenciais estáticas no container. | — |
| **Sem Redis** | A fila SQS já dessacopla a API do worker. Redis seria mais um serviço para gerenciar sem ganho claro. | Se houver pico de leitura, Redis poderia cachear resultados de consultas. |
| **Sem módulos públicos** | O código Terraform tem ~300 linhas. Módulos adicionariam complexidade sem ganho para este porte. | Menos reuso. Se o projeto crescer, refatorar em módulos. |

### O que ficou de fora por tempo ou custo

- **ECS/Fargate + Aurora**: Projeto de migração do contexto. Código pronto em [`migration/`](./migration/). Custo estimado: ~$55-70/mês.
- **Blue/Green deployment**: Exigiria ALB + target groups + ECS. O deploy atual (`docker stop && docker run`) tem downtime de segundos — aceitável para a janela de 5 min.
- **Multi-AZ (RDS + EC2)**: RDS multi-AZ custa 2x o banco. EC2 em 2 AZs exigiria ALB. Para o free tier e o porte do projeto, não justifica.
- **Application Load Balancer**: ~$22/mês mesmo parado. O Elastic IP é gratuito enquanto associado. Se o projeto fosse para staging/prod, ALB seria obrigatório.
- **Múltiplos workspaces automatizados**: staging e prod estão descritos, mas o pipeline atual só deploya em main.
- **CloudWatch Dashboard + Alarmes**: Free tier não cobre métricas detalhadas. Um dashboard custa ~$0/mês mas não foi priorizado.
- **Testes de integração no pipeline**: Valida apenas Terraform. Não há testes de API ou contrato.
- **WAF / CloudFront**: Aplicação não justifica CDN ou Web ACL para uma prova de conceito.

---

## 3. Como uma versão quebrada não chega em produção

### Pipeline (GitHub Actions)

```
                        ┌──────────────────────┐
         git push       │   GitHub Actions      │
  main ────────────────▶│                      │
                        │  ┌────────────────┐  │
                        │  │ Terraform Job   │  │
                        │  │                │  │
                        │  │  init          │  │
                        │  │  validate ◀────┼──┼── barreira 1: erro de sintaxe
                        │  │  plan    ◀────┼──┼── barreira 2: estado inconsistente
                        │  │  apply         │  │
                        │  └────────┬───────┘  │
                        │           │          │
                        │  ┌────────▼───────┐  │
                        │  │ Build & Deploy  │  │
                        │  │                │  │
                        │  │  docker build   │  │
                        │  │  docker push    │  │
                        │  │  wait EC2+SSM   │  │
                        │  │  docker run ◀──┼──┼── barreira 3: container não sobe
                        │  └────────────────┘  │
                        └──────────────────────┘
                                     │
                                     ▼
                               EC2 rodando
                               API :8080
```

Cada job só executa se o anterior passou. O workflow tem `continue-on-error: false` — qualquer falha para o pipeline e notifica.

### Proteção de branch

Configurar em Settings → Branches → Add rule:

- ☑ Require status checks before merging
- ☑ Require pull request before merging
- ☑ Do not allow bypass

Nada vai para `main` sem PR aprovado + pipeline verde.

### Rollback

**Rollback de código (mais comum):**

```bash
git revert HEAD --no-edit
git push origin main
```

O pipeline roda normal: builda a versão anterior e deploya. A imagem `:latest` no ECR é sobrescrita com o SHA do commit revertido.

**Rollback de emergência (via Actions UI — sem novo build):**

No repositório GitHub → **Actions** → **Deploy** → **Run workflow**:

```
Branch: main
rollback_sha: a1b2c3d  ← SHA do commit estável
```

Isso pula Terraform, não builda nada, e deploya diretamente a imagem
`a1b2c3d` que já existe no ECR (cada push salva a imagem com o SHA).

Para ver os SHAs disponíveis para rollback:

```bash
aws ecr describe-images --repository-name events-app \
  --query 'imageDetails[*].imageTags[*]' --output text
```

**Rollback de infraestrutura (Terraform):**

```bash
git checkout a1b2c3d
cd terraform
terraform apply -auto-approve
```

**Rollback de banco (RDS corrompido):**

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier events-app \
  --target-db-instance-identifier events-app-restored \
  --restore-time 2026-07-29T12:00:00
```

---

## 4. Como isso vira 4 ambientes (dev / prod)

| Ambiente | Infraestrutura | Deploy | Banco | SQS |
|---|---|---|---|---|
| **Local** | docker-compose (ElasticMQ + PostgreSQL) | `docker compose up` | PostgreSQL local | ElasticMQ (em memória) |
| **Railway (dev)** | PaaS — Railway gerencia | `git push railway main` | Railway PostgreSQL | Sem SQS (fallback in-memory) |
| **Staging** | AWS (workspace `staging`) | GH Actions (branch staging) | RDS `db.t3.micro` | SQS real |
| **Prod** | AWS (workspace `prod`) | GH Actions (branch main) | RDS `db.t3.micro` | SQS real |

### Onde o Railway entra

Railway é o **ambiente de desenvolvimento rápido**. Time faz testes manuais e de integração sem consumir recursos da AWS:

- Deploy é `git push` — sem Terraform, sem CI/CD complexo
- Railway PostgreSQL gerenciado — sem administrar RDS
- Zero configuração de VPC, Security Groups, IAM

### O que difere de prod

| Característica | Railway | Prod (AWS) |
|---|---|---|
| Provisionamento | PaaS (automático) | Terraform |
| Fila | In-memory (ou Redis Railway) | SQS |
| Rede | Pública (sem VPC) | VPC isolada |
| Worker | Thread na mesma app | Processo separado |
| Banco | Railway PostgreSQL | RDS PostgreSQL (subnet privada) |
| Infra como código | Não | Terraform + GitHub Actions |
| Segurança | SSL padrão | SG + IAM + Secrets Manager + SSM |

### Multi-ambiente com Terraform

```bash
# staging
terraform workspace new staging
terraform plan -var-file=staging.tfvars
terraform apply -var-file=staging.tfvars

# prod
terraform workspace select prod
terraform plan -var-file=prod.tfvars
terraform apply -var-file=prod.tfvars
```

Cada workspace tem seu próprio `terraform.tfstate`. As variáveis de cada ambiente (instance type, db class, etc.) ficam em `*.tfvars`.

---

## 5. Setup rápido

### 5.1. No GitHub — 2 secrets (2 minutos)

| Secret | Descrição | Onde pegar |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Access Key do IAM `terraform_usr` | `aws iam create-access-key --user-name terraform_usr` |
| `AWS_SECRET_ACCESS_KEY` | Secret Key do IAM `terraform_usr` | (mesmo comando acima) |

Settings → Secrets and variables → Actions → New repository secret.

### 5.2. No terminal — git push

```bash
git add .
git commit -m "feat: events-app"
git push origin main
```

O GitHub Actions faz todo o resto automaticamente:

```
git push
  └── GitHub Actions
       ├── terraform init + validate + plan
       ├── terraform apply
       │     ├── VPC + subnets + IGW
       │     ├── Security Groups (EC2 :8080, RDS :5432)
       │     ├── SQS Queue
       │     ├── ECR Repository
       │     ├── IAM Role (SQS + SSM + ECR + Secrets)
       │     ├── EC2 t2.micro (user_data instala Docker + Terraform + busca senha no Secrets Manager)
       │     ├── EIP
       │     └── RDS PostgreSQL + Secrets Manager
       ├── docker build + push → ECR
       ├── wait EC2 readiness + SSM agent
        └── SSM: docker run → API (:8080) + Worker
```

⏱ Tempo total esperado: **~12-15 minutos** (RDS demora ~8 min para provisionar).

Acompanhe em tempo real: **Actions → Deploy → logs**.

Se algo falhar, use **Run workflow** com `rollback_sha` para voltar à versão estável.

### 5.3. Testar

Assim que o workflow terminar (verde ✅ no Actions):

```bash
# Pegar o IP: vá em Terraform Outputs no Actions log, ou:
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=events-app" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text

IP=<cole_o_ip_aqui>
curl -X POST http://$IP:8080/events \
  -H 'Content-Type: application/json' \
  -d '{"type":"user.signup","data":{"email":"test@example.com"}}'
```

Acessos:

| URL | O que é |
|---|---|
| `http://<IP>:8080/` | Dashboard + POST /events |

### 5.4. Dev local (opcional)

```bash
docker compose up --build
# http://localhost:8080 (API + Dashboard)
```

Usa ElasticMQ (SQS fake) + PostgreSQL local.

---

## 6. Cleanup — custo zero

### Opção 1 — via GitHub Actions (recomendado)

No repositório GitHub → **Actions** → **Deploy** → **Run workflow**:

```
Branch: main
☐ destroy → marcar como true
```

Clique em **Run workflow**. O pipeline executa `terraform destroy -auto-approve` e apaga todos os recursos.

### Opção 2 — via CLI

**Verificação pós-destroy** — nenhum comando deve retornar resultado:

```bash
REGION=us-east-1

for query in \
  "ec2 describe-instances --filters Name=tag:Name,Values=events-app --query Reservations[*].Instances[*].InstanceId" \
  "rds describe-db-instances --filters Name=db-instance-id,Values=events-app --query DBInstances[*].DBInstanceIdentifier" \
  "ec2 describe-addresses --filters Name=tag:Name,Values=events-app --query Addresses[*].PublicIp" \
  "secretsmanager list-secrets --filters Key=name,Values=events-app/db-password --query SecretList[*].Name" \
  "ecr describe-repositories --repository-names events-app --query repositories[*].repositoryName" \
  "sqs list-queues --queue-name-prefix events-queue --output text" \
  "ec2 describe-security-groups --filters Name=group-name,Values=events-app-* --query SecurityGroups[*].GroupId" \
  "iam get-role --role-name events-app-ec2 --query Role.RoleName" \
  "ec2 describe-vpcs --filters Name=tag:Name,Values=events-app-vpc --query Vpcs[*].VpcId" \
  "ec2 describe-snapshots --owner-ids self --filters Name=tag:Name,Values=events-app --query Snapshots[*].SnapshotId" \
  "ec2 describe-volumes --filters Name=status,Values=available Name=tag:Name,Values=events-app --query Volumes[*].VolumeId"
do
  result=$(aws $query --region $REGION --output text 2>/dev/null)
  if [ -n "$result" ]; then echo "LEFT OVER: $query → $result"; fi
done

echo "Verificação concluída. Se nada apareceu acima, custo = \$0."
```

**Garantias:**

| Recurso | Proteção |
|---|---|
| RDS | `skip_final_snapshot = true` → sem snapshot residual |
| ECR | `force_delete = true` → apaga mesmo com imagens |
| Secrets Manager | `recovery_window_in_days = 0` → exclusão imediata |
| EC2 → EBS | `delete_on_termination` default = `true` |
| Elastic IP | Liberado com a EC2 |
| IAM | Roles/policies são recursos gerenciados — deletados com o workspace |

A senha do PostgreSQL é gerada automaticamente pelo `random_password` e armazenada no **AWS Secrets Manager** (`events-app/db-password`). **Nenhuma senha precisa ser configurada** nos secrets do GitHub.

---

## 7. Segurança

### O que NÃO está exposto

| Item | Status | Explicação |
|---|---|---|
| **AWS Access Keys** | 🔒 GitHub Secrets | Armazenadas criptografadas pelo GitHub. Só o workflow as vê (e mostra `***` nos logs). Nunca no código. |
| **DB Password** | 🔒 AWS Secrets Manager | Gerada por `random_password`, armazenada no Secrets Manager. EC2 busca via IAM role no boot. |
| **Credenciais na EC2** | 🔒 Nenhuma | EC2 usa Instance Profile (IAM role). Não há access key salva em arquivo ou env var. |
| **SSH** | 🔒 Bloqueado | Nenhuma porta 22 aberta. Deploy e gerenciamento são via SSM Session Manager. |
| **Worker + DB** | 🔒 Subnet privada | RDS está em subnet sem internet. Só a EC2 (subnet pública) alcança. |
| **Logs do Actions** | 🔒 Valores mascarados | GitHub exibe `***` no lugar de qualquer `${{ secrets.* }}`. |
| **Forks** | 🔒 Secrets não seguem | Repositórios forkados NÃO herdam os secrets do repositório original. |

### O que está público (e é seguro estar)

- **Código do workflow** (`deploy.yml`) — qualquer um vê que a pipeline usa secrets, mas não os valores
- **Código Terraform** — não contém senhas, apenas referências a recursos gerenciados
- **Código da aplicação** — não contém credenciais de nenhum tipo

### Fluxo da senha do banco (nunca em texto plano)

```
Terraform código
  └── random_password.db (recurso gerenciado, nunca visível no código)
       └── aws_secretsmanager_secret_version (armazena no Secrets Manager)
            └── EC2 boot → user_data.sh → IAM role → Secrets Manager API → DB_PASSWORD
                 └── docker run --env-file /opt/app/.env (injetado no container, nunca commitado)
                      └── docker exec (herda as variáveis do container)
```

A senha existe em apenas 3 lugares:
1. **Secrets Manager** (criptografado em repouso pela AWS KMS)
2. **RAM do container** (via variável de ambiente, nunca em disco)
3. **Conexão TCP** para o RDS (em trânsito, dentro da VPC)

Nunca está no repositório, no Terraform state, no código da aplicação, nem em logs.

- **IAM policy restrita**: Criar um user específico para o CI com permissões mínimas (EC2, RDS, SQS, ECR, SSM, Secrets) em vez de usar admin
- **Branch protection rules**: Exigir PR aprovado + status checks verdes antes de merge
- **OpenID Connect (OIDC)**: Substituir access keys por OIDC entre GitHub e AWS — sem secrets de longa duração
- **VPC Endpoints**: SQS e Secrets Manager por dentro da VPC, sem passar pelo IGW
- **WAF**: Rate limiting no endpoint público POST /events

---

## 8. IAM Permissions para o CI

O pipeline do GitHub Actions usa um IAM User (`terraform_usr`) com a política mínima abaixo.  
> ⚠️ Nota: a política listada aqui foi aplicada diretamente ao user, sem `AdministratorAccess`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeAddresses",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcs",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeRouteTables",
        "ec2:DescribeImages",
        "ec2:CreateVpc",
        "ec2:CreateSubnet",
        "ec2:CreateInternetGateway",
        "ec2:CreateRouteTable",
        "ec2:CreateRoute",
        "ec2:CreateSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:AttachInternetGateway",
        "ec2:AssociateRouteTable",
        "ec2:AllocateAddress",
        "ec2:AssociateAddress",
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:ReleaseAddress",
        "ec2:DeleteVpc",
        "ec2:DeleteSubnet",
        "ec2:DeleteInternetGateway",
        "ec2:DeleteRouteTable",
        "ec2:DeleteRoute",
        "ec2:DeleteSecurityGroup",
        "ec2:DetachInternetGateway",
        "ec2:DisassociateRouteTable",
        "ec2:CreateTags",
        "ec2:DescribeInstanceStatus",
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:PassRole",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagRole",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:DetachRolePolicy",
        "iam:AttachRolePolicy",
        "rds:CreateDBInstance",
        "rds:DeleteDBInstance",
        "rds:DescribeDBInstances",
        "rds:CreateDBSubnetGroup",
        "rds:DeleteDBSubnetGroup",
        "rds:DescribeDBSubnetGroups",
        "rds:ListTagsForResource",
        "sqs:CreateQueue",
        "sqs:DeleteQueue",
        "sqs:GetQueueUrl",
        "sqs:ListQueues",
        "sqs:GetQueueAttributes",
        "sqs:SetQueueAttributes",
        "sqs:TagQueue",
        "ecr:CreateRepository",
        "ecr:DeleteRepository",
        "ecr:DescribeRepositories",
        "ecr:GetAuthorizationToken",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "secretsmanager:CreateSecret",
        "secretsmanager:DeleteSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:TagResource",
        "ssm:DescribeInstanceInformation",
        "ssm:SendCommand",
        "ssm:ListCommandInvocations",
        "ssm:GetCommandInvocation",
        "s3:CreateBucket",
        "s3:PutBucketVersioning",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutEncryptionConfiguration",
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:GetBucketVersioning",
        "s3:GetBucketPublicAccessBlock",
        "s3:GetEncryptionConfiguration"
      ],
      "Resource": "*"
    }
  ]
}
```

**Dois secrets precisam ser configurados no repositório** (`Settings → Secrets and variables → Actions`):

| Secret | Descrição |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access Key ID do IAM User |
| `AWS_SECRET_ACCESS_KEY` | Secret Access Key do IAM User |

---

## 9. Possíveis melhorias futuras

### Salvaguardas deixadas para POC (não implementadas por tratar-se de prova de conceito free tier)

Esses itens foram **deliberadamente deixados de lado** porque o contexto é uma POC sem custos. Em produção, seriam obrigatórios:

| # | Salvaguarda | Por que ficou de fora | Risco sem ela |
|---|---|---|---|
| 1 | **OIDC (OpenID Connect)** no lugar de Access Keys estáticas | Configurar IAM Identity Provider exige permissão de Organizations, que conta dev free tier não tem | Access keys de longa duração no GitHub Secrets — se vazar, conta exposta |
| 2 | **DynamoDB para state locking** | S3 backend sem lock funciona para 1 dev. Com time > 1, dois applies simultâneos corrompem o state | State corrompido em deploys concorrentes |
| 3 | **Health check do Worker** | Pipeline valida só HTTP 200 da API. Worker pode estar morto sem ninguém saber | Eventos são publicados na SQS mas nunca persistidos |
| 4 | **USER não-root no Dockerfile** | Container roda como root. Em POC o risco é aceitável | Se a aplicação for comprometida, atacante tem root no container |
| 5 | **`chmod 600` no .env da senha** | O arquivo `/opt/app/.env` com a senha do banco fica legível para qualquer processo na EC2 | Escalação lateral via leak de credenciais do banco |
| 6 | **SCP (Service Control Policy)** | SCP exige AWS Organizations, que conta dev não tem | Admin consegue criar recursos fora do Terraform pelo console |

### Migration para Fargate + Aurora

O diretório [`migration/`](./migration/) contém a referência completa para substituir
EC2 + RDS por **ECS Fargate + Aurora Serverless**, conforme o roadmap do contexto:

- ALB (downtime zero, health check, circuit breaker)
- ECS Fargate com 2 tasks, deploy rolling automático
- Aurora Serverless v2 (escala de 0.5 a 2 ACU)
- IAM roles separadas para execução e task
- CloudWatch Logs com retenção de 7 dias

Para aplicar, veja o [`migration/README.md`](./migration/README.md).

### Imediatas (baixo esforço)

- **IAM policy restrita**: Criar user específico para o CI com permissões mínimas em vez de admin
- **OIDC entre GitHub e AWS**: Eliminar access keys — GitHub se autentica diretamente via IAM OIDC
- **S3 backend para Terraform**: State remoto e versionado. Habilita lock e colaboração em equipe.
- **Testes de API no pipeline**: `curl` ou `pytest` validando POST /events após deploy.
- **Múltiplos workspaces**: Automatizar staging + prod com `terraform workspace` no GitHub Actions.
- **Branch protection rules**: Exigir PR aprovado + status checks verdes antes de qualquer merge

### Médio prazo

- **ECS/Fargate + Aurora**: É o projeto de migração mencionado. Container gerenciado pela AWS, banco Aurora serverless. Downtime ≤ 5 min com deploy rolling.
- **Blue/Green deployment**: ALB + dois target groups. Deploy sem downtime.
- **CloudWatch Dashboard + Alarmes**: Métricas de SQS (ApproximateAgeOfOldestMessage), RDS (CPU/connections), HTTP 5xx.
- **WAF + CloudFront**: Rate limiting, proteção contra OWASP Top 10, edge caching.

### Longo prazo

- **GitOps com ArgoCD**: Estado desejado no Git, sync automático.
- **Multi-região**: us-east-1 + us-west-2 para DR.
- **Kubernetes (EKS)**: Se o número de serviços crescer além de 5-6 containers.
- **Testes de carga**: Validação de throughput antes de cada release.

**"E se alguém mexer no console da AWS?"**

O Terraform é **declarativo** — o `apply` sempre reconcilia o estado real com o código. Se alguém criar ou alterar um recurso no console, o próximo `terraform apply` sobrescreve. Mas a verdadeira proteção não é tecnológica, é **processo**:

| Medida | O que faz |
|---|---|
| **SCP** (AWS Organizations) | Bloqueia ações manuais na conta toda — ex.: negar `ec2:RunInstances` sem tag `managed-by:terraform` |
| **IAM policy restrita** | O time não tem permissão de escrita no console — só a pipeline |
| **Terraform** | Sempre força o estado de volta ao código. Um SG criado manualmente é deletado no próximo apply |

No projeto atual não implementei SCP porque é conta única dev. Em produção, a defesa real é **não dar acesso de escrita no console para ninguém** — tudo passa pelo CI/CD.

---

## 10. Resumo do que foi feito

### O projeto

API REST em FastAPI que recebe `POST /events`, publica em uma fila SQS, um worker consome e persiste em PostgreSQL. Tudo rodando em uma EC2 `t2.micro` via Docker, com RDS `db.t3.micro`.

### Infraestrutura provisionada (Terraform)

| Categoria | Recursos |
|---|---|
| **Rede** | VPC `10.0.0.0/16`, 2 subnets públicas, 2 privadas, Internet Gateway, route tables |
| **Compute** | EC2 t2.micro (Ubuntu 22.04) + Elastic IP fixo |
| **Banco** | RDS PostgreSQL 17 db.t3.micro (subnet privada, sem acesso internet) |
| **Mensageria** | SQS queue (20s long polling) |
| **Container** | ECR repository (`force_delete = true`) |
| **Segurança** | Secrets Manager (DB password), IAM role (SQS + SSM + ECR + Secrets), Security Groups |
| **State** | S3 bucket para state do Terraform (versionado, criptografado) |

### CI/CD (GitHub Actions)

- **Push na `main`** → terraform validate → plan → apply → docker build → push ECR → SSM deploy
- **Rollback** → `workflow_dispatch` com SHA do commit estável (deploy direto do ECR, sem Terraform)
- **Destroy** → `workflow_dispatch` com `destroy=true` → `terraform destroy -auto-approve`

### Segurança

- Credenciais AWS criptografadas no GitHub Secrets
- Senha do banco no Secrets Manager (nunca em texto plano no código)
- EC2 sem access keys (IAM instance profile)
- Sem SSH (SSM Session Manager)
- RDS em subnet privada

### Custo

~**$0/mês no primeiro ano** (free tier: t2.micro + db.t3.micro).
Após o primeiro ano: ~$15-20/mês (RDS db.t3.micro ~$15 + EC2 t2.micro ~$8).
