#!/bin/bash
set -ex

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq docker.io python3-pip python3-venv git curl unzip jq awscli

systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# Install Terraform (for frontend management tool)
curl -fsSL https://releases.hashicorp.com/terraform/1.9.0/terraform_1.9.0_linux_amd64.zip -o /tmp/tf.zip
unzip /tmp/tf.zip -d /usr/local/bin
rm /tmp/tf.zip

mkdir -p /opt/app

# Fetch DB password from Secrets Manager — nunca armazenada em texto plano
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id ${secret_arn} \
  --query SecretString \
  --region ${aws_region} \
  --output text)

cat > /opt/app/.env <<EOF
SQS_QUEUE_URL=${sqs_queue_url}
DB_HOST=${db_host}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=$DB_PASSWORD
AWS_REGION=${aws_region}
EOF

# Sinaliza que o setup terminou
touch /opt/app/.user_data_done
