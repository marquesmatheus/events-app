#!/bin/bash
set -e
REGION="${1:-us-east-1}"
echo "=== Nuke: deleting all resources tagged events-app* ==="

# 1. RDS — force delete + wait
DB_ID="events-app"
if aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region $REGION &>/dev/null; then
  echo "[1/9] Deleting RDS..."
  aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot --region $REGION 2>/dev/null || true
  for i in $(seq 1 60); do
    STATUS=$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" --region $REGION \
      --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "gone")
    [ "$STATUS" = "gone" ] && break
    echo "  RDS: $STATUS ($i/60)"
    sleep 10
  done
fi

# 2. EC2 — terminate + wait
INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=events-app" --region $REGION \
  --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null || echo "")
if [ -n "$INSTANCE_IDS" ]; then
  echo "[2/9] Terminating EC2: $INSTANCE_IDS"
  aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region $REGION 2>/dev/null || true
  for id in $INSTANCE_IDS; do
    for i in $(seq 1 30); do
      STATE=$(aws ec2 describe-instances --instance-ids "$id" --region $REGION \
        --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "terminated")
      [ "$STATE" = "terminated" ] && break
      echo "  EC2 $id: $STATE ($i/30)"
      sleep 10
    done
  done
fi

# 3. EIP — release
ALLOC_IDS=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=events-app" --region $REGION \
  --query 'Addresses[*].AllocationId' --output text 2>/dev/null || echo "")
if [ -n "$ALLOC_IDS" ]; then
  echo "[3/9] Releasing EIPs..."
  for id in $ALLOC_IDS; do
    aws ec2 release-address --allocation-id "$id" --region $REGION 2>/dev/null || true
  done
fi

# 4. ENIs — find and delete (block SGs from being deleted)
echo "[4/9] Deleting network interfaces..."
for sg in $(aws ec2 describe-security-groups --filters "Name=group-name,Values=events-app-*" --region $REGION \
  --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || echo ""); do
  for eni in $(aws ec2 describe-network-interfaces --filters "Name=group-id,Values=$sg" --region $REGION \
    --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null || echo ""); do
    echo "  Deleting ENI $eni (SG $sg)"
    aws ec2 delete-network-interface --network-interface-id "$eni" --region $REGION 2>/dev/null || true
  done
done

# 5. SGs
echo "[5/9] Deleting security groups..."
for sg in $(aws ec2 describe-security-groups --filters "Name=group-name,Values=events-app-*" --region $REGION \
  --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || echo ""); do
  aws ec2 delete-security-group --group-id "$sg" --region $REGION 2>/dev/null || true
done

# 6. IAM
echo "[6/9] Deleting IAM..."
aws iam remove-role-from-instance-profile --instance-profile-name events-app-ec2 --role-name events-app-ec2 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name events-app-ec2 2>/dev/null || true
for policy_name in $(aws iam list-role-policies --role-name events-app-ec2 --query 'PolicyNames[*]' --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name events-app-ec2 --policy-name "$policy_name" 2>/dev/null || true
done
for policy_arn in $(aws iam list-attached-role-policies --role-name events-app-ec2 --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
  aws iam detach-role-policy --role-name events-app-ec2 --policy-arn "$policy_arn" 2>/dev/null || true
done
aws iam delete-role --role-name events-app-ec2 2>/dev/null || true

# 7. SQS + ECR + Secrets Manager
echo "[7/9] Deleting SQS, ECR, Secrets..."
QUEUE_URL=$(aws sqs get-queue-url --queue-name events-queue --region $REGION --query QueueUrl --output text 2>/dev/null || echo "")
[ -n "$QUEUE_URL" ] && aws sqs delete-queue --queue-url "$QUEUE_URL" --region $REGION 2>/dev/null || true
aws ecr delete-repository --repository-name events-app --force --region $REGION 2>/dev/null || true
aws secretsmanager delete-secret --secret-id events-app/db-password --force-delete-without-recovery --region $REGION 2>/dev/null || true

# 8. RDS subnet group
aws rds delete-db-subnet-group --db-subnet-group-name events-app --region $REGION 2>/dev/null || true

# 9. VPC — delete all dependencies then VPC
echo "[8/9] Deleting VPC resources..."
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=events-app-vpc" --region $REGION \
  --query 'Vpcs[*].VpcId' --output text 2>/dev/null || echo "")
if [ -n "$VPC_ID" ]; then
  # IGW
  IGW_ID=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC_ID" --region $REGION \
    --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null || echo "")
  if [ -n "$IGW_ID" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region $REGION 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID" --region $REGION 2>/dev/null || true
  fi
  # Subnets
  for subnet_id in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION \
    --query 'Subnets[*].SubnetId' --output text 2>/dev/null); do
    aws ec2 delete-subnet --subnet-id "$subnet_id" --region $REGION 2>/dev/null || true
  done
  # Route tables (non-main)
  MAIN_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" --region $REGION \
    --query 'RouteTables[*].RouteTableId' --output text 2>/dev/null || echo "")
  for rt_id in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" --region $REGION \
    --query 'RouteTables[*].RouteTableId' --output text 2>/dev/null); do
    if [ "$rt_id" != "$MAIN_RT" ]; then
      aws ec2 delete-route-table --route-table-id "$rt_id" --region $REGION 2>/dev/null || true
    fi
  done
  # VPC
  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region $REGION 2>/dev/null || true
fi

# S3 bucket (terraform state)
echo "[9/9] Deleting S3 bucket..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
BUCKET="events-app-tfstate-$ACCOUNT_ID"
if aws s3api head-bucket --bucket "$BUCKET" --region $REGION 2>/dev/null; then
  aws s3 rm "s3://$BUCKET" --recursive --region $REGION 2>/dev/null || true
  aws s3api delete-bucket --bucket "$BUCKET" --region $REGION 2>/dev/null || true
fi

echo "=== Nuke complete ==="
