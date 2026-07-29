#!/bin/bash
set -e
REGION="${1:-us-east-1}"
echo "=============================================="
echo "  ACCOUNT NUKE - DELETES EVERYTHING"
echo "  Region: $REGION"
echo "=============================================="
echo "  WARNING: This will delete ALL resources"
echo "  in your AWS account. This is IRREVERSIBLE."
echo "=============================================="
read -p "Type 'NUKE' to confirm: " confirm
if [ "$confirm" != "NUKE" ]; then
  echo "Cancelled."
  exit 1
fi
echo "=============================================="
echo "  Starting nuke..."
echo "=============================================="

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ──────────────────────────────────────────────
# 1. RDS
# ──────────────────────────────────────────────
echo "[1] RDS instances..."
for db in $(aws rds describe-db-instances --region $REGION --query 'DBInstances[*].DBInstanceIdentifier' --output text 2>/dev/null); do
  echo "  Deleting RDS: $db"
  aws rds delete-db-instance --db-instance-identifier "$db" --skip-final-snapshot --region $REGION 2>/dev/null || true
done
for db in $(aws rds describe-db-instances --region $REGION --query 'DBInstances[*].DBInstanceIdentifier' --output text 2>/dev/null); do
  echo "  Waiting for RDS: $db"
  for i in $(seq 1 60); do
    STATUS=$(aws rds describe-db-instances --db-instance-identifier "$db" --region $REGION --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "gone")
    [ "$STATUS" = "gone" ] && break
    sleep 10
  done
done

# ──────────────────────────────────────────────
# 2. RDS subnet groups
# ──────────────────────────────────────────────
echo "[2] RDS subnet groups..."
for sg in $(aws rds describe-db-subnet-groups --region $REGION --query 'DBSubnetGroups[*].DBSubnetGroupName' --output text 2>/dev/null); do
  echo "  Deleting RDS subnet group: $sg"
  aws rds delete-db-subnet-group --db-subnet-group-name "$sg" --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 3. EC2 instances (terminate)
# ──────────────────────────────────────────────
echo "[3] EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances --region $REGION --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null)
if [ -n "$INSTANCE_IDS" ]; then
  echo "  Terminating: $INSTANCE_IDS"
  aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region $REGION 2>/dev/null || true
  for id in $INSTANCE_IDS; do
    for i in $(seq 1 30); do
      STATE=$(aws ec2 describe-instances --instance-ids "$id" --region $REGION --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "terminated")
      [ "$STATE" = "terminated" ] && break
      sleep 10
    done
  done
fi

# ──────────────────────────────────────────────
# 4. Elastic IPs
# ──────────────────────────────────────────────
echo "[4] Elastic IPs..."
for alloc in $(aws ec2 describe-addresses --region $REGION --query 'Addresses[*].AllocationId' --output text 2>/dev/null); do
  echo "  Releasing EIP: $alloc"
  aws ec2 release-address --allocation-id "$alloc" --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 5. ALBs / NLBs
# ──────────────────────────────────────────────
echo "[5] Load balancers..."
for lb in $(aws elbv2 describe-load-balancers --region $REGION --query 'LoadBalancers[*].LoadBalancerArn' --output text 2>/dev/null); do
  echo "  Deleting LB: $lb"
  aws elbv2 delete-load-balancer --load-balancer-arn "$lb" --region $REGION 2>/dev/null || true
done
for tg in $(aws elbv2 describe-target-groups --region $REGION --query 'TargetGroups[*].TargetGroupArn' --output text 2>/dev/null); do
  echo "  Deleting target group: $tg"
  aws elbv2 delete-target-group --target-group-arn "$tg" --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 6. NAT Gateways
# ──────────────────────────────────────────────
echo "[6] NAT Gateways..."
for nat in $(aws ec2 describe-nat-gateways --region $REGION --filter "Name=state,Values=pending,available" --query 'NatGateways[*].NatGatewayId' --output text 2>/dev/null); do
  echo "  Deleting NAT: $nat"
  aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 7. Lambda functions
# ──────────────────────────────────────────────
echo "[7] Lambda functions..."
for fn in $(aws lambda list-functions --region $REGION --query 'Functions[*].FunctionName' --output text 2>/dev/null); do
  echo "  Deleting Lambda: $fn"
  aws lambda delete-function --function-name "$fn" --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 8. ECS clusters
# ──────────────────────────────────────────────
echo "[8] ECS clusters & services..."
for cluster in $(aws ecs list-clusters --region $REGION --query 'clusterArns[*]' --output text 2>/dev/null); do
  for service in $(aws ecs list-services --cluster "$cluster" --region $REGION --query 'serviceArns[*]' --output text 2>/dev/null); do
    echo "  Deleting ECS service: $service"
    aws ecs update-service --cluster "$cluster" --service "$service" --desired-count 0 --region $REGION 2>/dev/null || true
    aws ecs delete-service --cluster "$cluster" --service "$service" --force --region $REGION 2>/dev/null || true
  done
  echo "  Deleting ECS cluster: $cluster"
  aws ecs delete-cluster --cluster "$cluster" --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 9. SQS queues
# ──────────────────────────────────────────────
echo "[9] SQS queues..."
for queue in $(aws sqs list-queues --region $REGION --output text 2>/dev/null | tr '\t' '\n'); do
  [ -z "$queue" ] && continue
  echo "  Deleting SQS: $queue"
  aws sqs delete-queue --queue-url "$queue" --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 10. ECR repositories
# ──────────────────────────────────────────────
echo "[10] ECR repositories..."
for repo in $(aws ecr describe-repositories --region $REGION --query 'repositories[*].repositoryName' --output text 2>/dev/null); do
  echo "  Deleting ECR: $repo"
  aws ecr delete-repository --repository-name "$repo" --force --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 11. Secrets Manager
# ──────────────────────────────────────────────
echo "[11] Secrets Manager..."
for secret in $(aws secretsmanager list-secrets --region $REGION --query 'SecretList[*].Name' --output text 2>/dev/null); do
  echo "  Deleting secret: $secret"
  aws secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 12. IAM roles, instance profiles, policies
# ──────────────────────────────────────────────
echo "[12] IAM..."
for profile in $(aws iam list-instance-profiles --query 'InstanceProfiles[*].InstanceProfileName' --output text 2>/dev/null); do
  for role in $(aws iam get-instance-profile --instance-profile-name "$profile" --query 'InstanceProfile.Roles[*].RoleName' --output text 2>/dev/null); do
    aws iam remove-role-from-instance-profile --instance-profile-name "$profile" --role-name "$role" 2>/dev/null || true
  done
  aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null || true
done

for role in $(aws iam list-roles --query 'Roles[*].RoleName' --output text 2>/dev/null); do
  # Skip AWS service roles
  case "$role" in
    aws-service-role/*|AWSServiceRoleFor*) continue ;;
  esac
  echo "  Deleting IAM role: $role"
  for policy_name in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[*]' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$policy_name" 2>/dev/null || true
  done
  for policy_arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$policy_arn" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$role" 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 13. Network Interfaces (blockers for SG/VPC)
# ──────────────────────────────────────────────
echo "[13] Network interfaces..."
for eni in $(aws ec2 describe-network-interfaces --region $REGION --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null); do
  echo "  Deleting ENI: $eni"
  aws ec2 delete-network-interface --network-interface-id "$eni" --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 14. Security Groups (non-default)
# ──────────────────────────────────────────────
echo "[14] Security groups..."
for sg in $(aws ec2 describe-security-groups --region $REGION --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null); do
  echo "  Deleting SG: $sg"
  aws ec2 delete-security-group --group-id "$sg" --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 15. VPCs (non-default)
# ──────────────────────────────────────────────
echo "[15] VPC resources..."
for vpc in $(aws ec2 describe-vpcs --region $REGION --query 'Vpcs[?IsDefault==`false`].VpcId' --output text 2>/dev/null); do
  echo "  Processing VPC: $vpc"

  # IGW
  for igw in $(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --region $REGION --query 'InternetGateways[*].InternetGatewayId' --output text 2>/dev/null); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc" --region $REGION 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region $REGION 2>/dev/null || true
  done

  # Subnets
  for subnet in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --region $REGION --query 'Subnets[*].SubnetId' --output text 2>/dev/null); do
    aws ec2 delete-subnet --subnet-id "$subnet" --region $REGION 2>/dev/null || true
  done

  # Route tables (non-main)
  MAIN_RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" "Name=association.main,Values=true" --region $REGION --query 'RouteTables[*].RouteTableId' --output text 2>/dev/null)
  for rt in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" --region $REGION --query 'RouteTables[*].RouteTableId' --output text 2>/dev/null); do
    if [ "$rt" != "$MAIN_RT" ]; then
      aws ec2 delete-route-table --route-table-id "$rt" --region $REGION 2>/dev/null || true
    fi
  done

  # VPC
  aws ec2 delete-vpc --vpc-id "$vpc" --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 16. CloudWatch Log Groups
# ──────────────────────────────────────────────
echo "[16] CloudWatch log groups..."
for group in $(aws logs describe-log-groups --region $REGION --query 'logGroups[*].logGroupName' --output text 2>/dev/null); do
  echo "  Deleting log group: $group"
  aws logs delete-log-group --log-group-name "$group" --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# 17. S3 buckets
# ──────────────────────────────────────────────
echo "[17] S3 buckets..."
for bucket in $(aws s3api list-buckets --query 'Buckets[*].Name' --output text 2>/dev/null); do
  case "$bucket" in
    *aws-glue*|*cloudtrail*|*config*|*log*) continue ;;
  esac
  echo "  Deleting S3: $bucket"
  aws s3 rm "s3://$bucket" --recursive --region $REGION 2>/dev/null || true
  aws s3api delete-bucket --bucket "$bucket" --region $REGION 2>/dev/null || true
done

# ──────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────
echo "=============================================="
echo "  Nuke complete!"
echo "  Account: $ACCOUNT_ID"
echo "  Region: $REGION"
echo "=============================================="
echo ""
echo "Verification - remaining resources by type:"
echo "  RDS:      $(aws rds describe-db-instances --region $REGION --query 'length(DBInstances)' --output text 2>/dev/null || echo 0)"
echo "  EC2:      $(aws ec2 describe-instances --region $REGION --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'length(Reservations[*].Instances[*].InstanceId)' --output text 2>/dev/null || echo 0)"
echo "  EIP:      $(aws ec2 describe-addresses --region $REGION --query 'length(Addresses)' --output text 2>/dev/null || echo 0)"
echo "  NAT:      $(aws ec2 describe-nat-gateways --region $REGION --filter Name=state,Values=pending,available --query 'length(NatGateways)' --output text 2>/dev/null || echo 0)"
echo "  VPCs:     $(aws ec2 describe-vpcs --region $REGION --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)"
