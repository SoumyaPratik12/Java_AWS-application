#!/usr/bin/env bash
# Full AWS ECS Fargate deployment script for my-app microservices
# Usage: AWS credentials must be configured before running
set -euo pipefail

REGION="ap-south-1"
PROJECT="my-app"
ENV="prod"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/my-app"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# Verify AWS credentials
log "Verifying AWS credentials..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION") \
  || die "AWS credentials not configured. Run: aws configure"
log "Account ID: $ACCOUNT_ID"
ECR_BASE="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

# ─── STEP 3: VPC AND NETWORKING ──────────────────────────────────────────────
log "=== STEP 3: Creating VPC and networking ==="

VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=my-app-vpc},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'Vpc.VpcId' --output text --region "$REGION")
log "VPC created: $VPC_ID"

aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames --region "$REGION"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support --region "$REGION"

IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=my-app-igw},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'InternetGateway.InternetGatewayId' --output text --region "$REGION")
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" --region "$REGION"
log "IGW: $IGW_ID attached to VPC"

PUB_SUB_1=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
  --cidr-block 10.0.1.0/24 --availability-zone "${REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=public-1a},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'Subnet.SubnetId' --output text --region "$REGION")

PUB_SUB_2=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
  --cidr-block 10.0.2.0/24 --availability-zone "${REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=public-1b},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'Subnet.SubnetId' --output text --region "$REGION")

PRIV_SUB_1=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
  --cidr-block 10.0.3.0/24 --availability-zone "${REGION}a" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=private-1a},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'Subnet.SubnetId' --output text --region "$REGION")

PRIV_SUB_2=$(aws ec2 create-subnet --vpc-id "$VPC_ID" \
  --cidr-block 10.0.4.0/24 --availability-zone "${REGION}b" \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=private-1b},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'Subnet.SubnetId' --output text --region "$REGION")

log "Subnets: pub1=$PUB_SUB_1 pub2=$PUB_SUB_2 priv1=$PRIV_SUB_1 priv2=$PRIV_SUB_2"

# Enable auto-assign public IP on public subnets
aws ec2 modify-subnet-attribute --subnet-id "$PUB_SUB_1" --map-public-ip-on-launch --region "$REGION"
aws ec2 modify-subnet-attribute --subnet-id "$PUB_SUB_2" --map-public-ip-on-launch --region "$REGION"

# Public route table
PUB_RTB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=public-rtb},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'RouteTable.RouteTableId' --output text --region "$REGION")
aws ec2 create-route --route-table-id "$PUB_RTB" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PUB_RTB" --subnet-id "$PUB_SUB_1" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PUB_RTB" --subnet-id "$PUB_SUB_2" --region "$REGION" > /dev/null
log "Public route table created: $PUB_RTB"

# NAT Gateway
EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=my-app-nat-eip},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'AllocationId' --output text --region "$REGION")
NAT_GW=$(aws ec2 create-nat-gateway \
  --subnet-id "$PUB_SUB_1" --allocation-id "$EIP_ALLOC" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=my-app-nat},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'NatGateway.NatGatewayId' --output text --region "$REGION")
log "NAT Gateway $NAT_GW created. Waiting for available state (up to 3 minutes)..."
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_GW" --region "$REGION"
log "NAT Gateway is available."

# Private route table
PRIV_RTB=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=private-rtb},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'RouteTable.RouteTableId' --output text --region "$REGION")
aws ec2 create-route --route-table-id "$PRIV_RTB" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PRIV_RTB" --subnet-id "$PRIV_SUB_1" --region "$REGION" > /dev/null
aws ec2 associate-route-table --route-table-id "$PRIV_RTB" --subnet-id "$PRIV_SUB_2" --region "$REGION" > /dev/null
log "Private route table created: $PRIV_RTB"

# Security Groups
ALB_SG=$(aws ec2 create-security-group \
  --group-name my-app-alb-sg --description "ALB security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=my-app-alb-sg},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'GroupId' --output text --region "$REGION")
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" \
  --ip-permissions '[{"IpProtocol":"tcp","FromPort":80,"ToPort":80,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]},{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' \
  --region "$REGION" > /dev/null

ECS_SG=$(aws ec2 create-security-group \
  --group-name my-app-ecs-sg --description "ECS tasks security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=my-app-ecs-sg},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'GroupId' --output text --region "$REGION")
aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":8081,\"ToPort\":8083,\"UserIdGroupPairs\":[{\"GroupId\":\"$ALB_SG\"}]}]" \
  --region "$REGION" > /dev/null

RDS_SG=$(aws ec2 create-security-group \
  --group-name my-app-rds-sg --description "RDS security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=my-app-rds-sg},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'GroupId' --output text --region "$REGION")
aws ec2 authorize-security-group-ingress --group-id "$RDS_SG" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":3306,\"ToPort\":3306,\"UserIdGroupPairs\":[{\"GroupId\":\"$ECS_SG\"}]}]" \
  --region "$REGION" > /dev/null

REDIS_SG=$(aws ec2 create-security-group \
  --group-name my-app-redis-sg --description "Redis security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=my-app-redis-sg},{Key=Project,Value=my-app},{Key=Env,Value=prod}]" \
  --query 'GroupId' --output text --region "$REGION")
aws ec2 authorize-security-group-ingress --group-id "$REDIS_SG" \
  --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":6379,\"ToPort\":6379,\"UserIdGroupPairs\":[{\"GroupId\":\"$ECS_SG\"}]}]" \
  --region "$REGION" > /dev/null

log "Security groups: ALB=$ALB_SG ECS=$ECS_SG RDS=$RDS_SG REDIS=$REDIS_SG"

# ─── STEP 4: ECR REPOSITORIES AND PUSH ──────────────────────────────────────
log "=== STEP 4: Creating ECR repositories and pushing images ==="

for SVC in user-service order-service notification-service; do
  aws ecr create-repository \
    --repository-name "my-app/$SVC" \
    --image-scanning-configuration scanOnPush=true \
    --tags "[{\"Key\":\"Project\",\"Value\":\"my-app\"},{\"Key\":\"Env\",\"Value\":\"prod\"}]" \
    --region "$REGION" > /dev/null
  log "ECR repo created: my-app/$SVC"
done

aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ECR_BASE"

for SVC in user-service order-service notification-service; do
  docker tag "my-app/$SVC:latest" "$ECR_BASE/my-app/$SVC:latest"
  log "Pushing $SVC to ECR..."
  docker push "$ECR_BASE/my-app/$SVC:latest"
  log "Pushed: $ECR_BASE/my-app/$SVC:latest"
done

# ─── STEP 5: SECRETS MANAGER ─────────────────────────────────────────────────
log "=== STEP 5: Creating Secrets Manager secrets ==="

DB_SECRET_ARN=$(aws secretsmanager create-secret \
  --name "my-app/prod/db" \
  --secret-string '{"DB_HOST":"placeholder","DB_PORT":"3306","DB_NAME":"myappdb","DB_USERNAME":"admin","DB_PASSWORD":"changeme123"}' \
  --tags '[{"Key":"Project","Value":"my-app"},{"Key":"Env","Value":"prod"}]' \
  --region "$REGION" \
  --query 'ARN' --output text)
log "DB Secret ARN: $DB_SECRET_ARN"

REDIS_SECRET_ARN=$(aws secretsmanager create-secret \
  --name "my-app/prod/redis" \
  --secret-string '{"REDIS_HOST":"placeholder","REDIS_PASSWORD":"changeme123"}' \
  --tags '[{"Key":"Project","Value":"my-app"},{"Key":"Env","Value":"prod"}]' \
  --region "$REGION" \
  --query 'ARN' --output text)
log "Redis Secret ARN: $REDIS_SECRET_ARN"

# ─── STEP 6: IAM ROLES ───────────────────────────────────────────────────────
log "=== STEP 6: Creating IAM roles ==="

cat > /tmp/ecs-trust-policy.json << 'TRUST'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ecs-tasks.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
TRUST

# Task Execution Role
EXEC_ROLE_ARN=$(aws iam create-role \
  --role-name ecsTaskExecutionRole-my-app \
  --assume-role-policy-document file:///tmp/ecs-trust-policy.json \
  --tags '[{"Key":"Project","Value":"my-app"},{"Key":"Env","Value":"prod"}]' \
  --query 'Role.Arn' --output text)
aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole-my-app \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

cat > /tmp/exec-inline-policy.json << POLICY
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["secretsmanager:GetSecretValue"],
    "Resource": "arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:my-app/prod/*"
  }]
}
POLICY
aws iam put-role-policy \
  --role-name ecsTaskExecutionRole-my-app \
  --policy-name SecretsAccess \
  --policy-document file:///tmp/exec-inline-policy.json
log "Execution role: $EXEC_ROLE_ARN"

# Task Role
TASK_ROLE_ARN=$(aws iam create-role \
  --role-name ecsTaskRole-my-app \
  --assume-role-policy-document file:///tmp/ecs-trust-policy.json \
  --tags '[{"Key":"Project","Value":"my-app"},{"Key":"Env","Value":"prod"}]' \
  --query 'Role.Arn' --output text)

cat > /tmp/task-inline-policy.json << 'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["sqs:SendMessage","sqs:ReceiveMessage","sqs:DeleteMessage"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream","logs:PutLogEvents"],
      "Resource": "*"
    }
  ]
}
POLICY
aws iam put-role-policy \
  --role-name ecsTaskRole-my-app \
  --policy-name TaskPermissions \
  --policy-document file:///tmp/task-inline-policy.json
log "Task role: $TASK_ROLE_ARN"

# ─── STEP 7: CLOUDWATCH LOG GROUPS ──────────────────────────────────────────
log "=== STEP 7: Creating CloudWatch log groups ==="

for SVC in user-service order-service notification-service; do
  aws logs create-log-group --log-group-name "/ecs/$SVC" --region "$REGION"
  aws logs put-retention-policy --log-group-name "/ecs/$SVC" --retention-in-days 30 --region "$REGION"
  log "Log group: /ecs/$SVC (30 day retention)"
done

# ─── STEP 8: ECS CLUSTER AND TASK DEFINITIONS ────────────────────────────────
log "=== STEP 8: Creating ECS cluster and task definitions ==="

aws ecs create-cluster \
  --cluster-name my-app-cluster \
  --settings name=containerInsights,value=enabled \
  --tags '[{"key":"Project","value":"my-app"},{"key":"Env","value":"prod"}]' \
  --region "$REGION" > /dev/null
log "ECS cluster created: my-app-cluster"

declare -A SVC_PORTS=( [user-service]=8081 [order-service]=8082 [notification-service]=8083 )

for SVC in user-service order-service notification-service; do
  PORT="${SVC_PORTS[$SVC]}"
  TASKDEF_FILE="/tmp/${SVC}-taskdef.json"
  cat > "$TASKDEF_FILE" << TASKDEF
{
  "family": "$SVC",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "$EXEC_ROLE_ARN",
  "taskRoleArn": "$TASK_ROLE_ARN",
  "tags": [
    {"key": "Project", "value": "my-app"},
    {"key": "Env", "value": "prod"}
  ],
  "containerDefinitions": [{
    "name": "$SVC",
    "image": "$ECR_BASE/my-app/$SVC:latest",
    "essential": true,
    "portMappings": [{
      "containerPort": $PORT,
      "protocol": "tcp"
    }],
    "environment": [
      {"name": "SPRING_PROFILES_ACTIVE", "value": "prod"},
      {"name": "SERVER_PORT", "value": "$PORT"}
    ],
    "secrets": [
      {"name": "DB_PASSWORD", "valueFrom": "${DB_SECRET_ARN}:DB_PASSWORD::"},
      {"name": "DB_HOST", "valueFrom": "${DB_SECRET_ARN}:DB_HOST::"},
      {"name": "DB_PORT", "valueFrom": "${DB_SECRET_ARN}:DB_PORT::"},
      {"name": "DB_NAME", "valueFrom": "${DB_SECRET_ARN}:DB_NAME::"},
      {"name": "DB_USERNAME", "valueFrom": "${DB_SECRET_ARN}:DB_USERNAME::"}
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/$SVC",
        "awslogs-region": "$REGION",
        "awslogs-stream-prefix": "ecs"
      }
    },
    "healthCheck": {
      "command": ["CMD-SHELL", "curl -f http://localhost:$PORT/actuator/health || exit 1"],
      "interval": 30,
      "timeout": 5,
      "retries": 3,
      "startPeriod": 60
    }
  }]
}
TASKDEF
  aws ecs register-task-definition \
    --cli-input-json "file://$TASKDEF_FILE" \
    --region "$REGION" > /dev/null
  cp "$TASKDEF_FILE" "${APP_DIR}/../${SVC}-taskdef.json"
  log "Task definition registered: $SVC (port $PORT)"
done

# ─── STEP 9: ALB, TARGET GROUPS, LISTENER RULES ──────────────────────────────
log "=== STEP 9: Creating ALB, target groups, and listener rules ==="

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name my-app-alb \
  --subnets "$PUB_SUB_1" "$PUB_SUB_2" \
  --security-groups "$ALB_SG" \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --tags '[{"Key":"Project","Value":"my-app"},{"Key":"Env","Value":"prod"}]' \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION")

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text --region "$REGION")
log "ALB: $ALB_DNS"

TG_USER_ARN=$(aws elbv2 create-target-group \
  --name my-app-user-tg \
  --protocol HTTP --port 8081 --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-path /actuator/health \
  --health-check-port traffic-port \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --tags '[{"Key":"Project","Value":"my-app"},{"Key":"Env","Value":"prod"}]' \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION")

TG_ORDER_ARN=$(aws elbv2 create-target-group \
  --name my-app-order-tg \
  --protocol HTTP --port 8082 --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-path /actuator/health \
  --health-check-port traffic-port \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --tags '[{"Key":"Project","Value":"my-app"},{"Key":"Env","Value":"prod"}]' \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION")

TG_NOTIF_ARN=$(aws elbv2 create-target-group \
  --name my-app-notif-tg \
  --protocol HTTP --port 8083 --vpc-id "$VPC_ID" \
  --target-type ip \
  --health-check-path /actuator/health \
  --health-check-port traffic-port \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --tags '[{"Key":"Project","Value":"my-app"},{"Key":"Env","Value":"prod"}]' \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION")

log "Target groups: user=$TG_USER_ARN order=$TG_ORDER_ARN notif=$TG_NOTIF_ARN"

LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions 'Type=fixed-response,FixedResponseConfig={StatusCode=404,ContentType=application/json,MessageBody={"error":"not found"}}' \
  --tags '[{"Key":"Project","Value":"my-app"},{"Key":"Env","Value":"prod"}]' \
  --query 'Listeners[0].ListenerArn' --output text --region "$REGION")

aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" --priority 10 \
  --conditions 'Field=path-pattern,Values=["/api/v1/users/*"]' \
  --actions "Type=forward,TargetGroupArn=$TG_USER_ARN" \
  --region "$REGION" > /dev/null

aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" --priority 20 \
  --conditions 'Field=path-pattern,Values=["/api/v1/orders/*"]' \
  --actions "Type=forward,TargetGroupArn=$TG_ORDER_ARN" \
  --region "$REGION" > /dev/null

aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" --priority 30 \
  --conditions 'Field=path-pattern,Values=["/api/v1/notifications/*"]' \
  --actions "Type=forward,TargetGroupArn=$TG_NOTIF_ARN" \
  --region "$REGION" > /dev/null

log "Listener rules created (users→8081, orders→8082, notifications→8083)"

# ─── STEP 10: ECS SERVICES ───────────────────────────────────────────────────
log "=== STEP 10: Creating ECS services ==="

declare -A SVC_TGS=( [user-service]="$TG_USER_ARN" [order-service]="$TG_ORDER_ARN" [notification-service]="$TG_NOTIF_ARN" )

for SVC in user-service order-service notification-service; do
  PORT="${SVC_PORTS[$SVC]}"
  TG="${SVC_TGS[$SVC]}"
  SVC_FILE="/tmp/${SVC}-svc.json"
  cat > "$SVC_FILE" << SVCCFG
{
  "cluster": "my-app-cluster",
  "serviceName": "$SVC",
  "taskDefinition": "$SVC",
  "desiredCount": 1,
  "launchType": "FARGATE",
  "networkConfiguration": {
    "awsvpcConfiguration": {
      "subnets": ["$PRIV_SUB_1", "$PRIV_SUB_2"],
      "securityGroups": ["$ECS_SG"],
      "assignPublicIp": "DISABLED"
    }
  },
  "loadBalancers": [{
    "targetGroupArn": "$TG",
    "containerName": "$SVC",
    "containerPort": $PORT
  }],
  "healthCheckGracePeriodSeconds": 120,
  "deploymentConfiguration": {
    "minimumHealthyPercent": 50,
    "maximumPercent": 200
  },
  "tags": [
    {"key": "Project", "value": "my-app"},
    {"key": "Env", "value": "prod"}
  ]
}
SVCCFG
  aws ecs create-service --cli-input-json "file://$SVC_FILE" --region "$REGION" > /dev/null
  cp "$SVC_FILE" "${APP_DIR}/../${SVC}-svc.json"
  log "ECS service created: $SVC"
done

# Wait for all tasks to be RUNNING
log "Waiting for all ECS tasks to reach RUNNING state (polling every 30s)..."
TIMEOUT=600
ELAPSED=0
while true; do
  STATUS=$(aws ecs describe-services \
    --cluster my-app-cluster \
    --services user-service order-service notification-service \
    --region "$REGION" \
    --query 'services[*].{name:serviceName,running:runningCount,desired:desiredCount}' \
    --output json)
  RUNNING=$(echo "$STATUS" | python3 -c "
import json,sys
svcs = json.load(sys.stdin)
all_ok = all(s['running'] == s['desired'] for s in svcs)
print('YES' if all_ok else 'NO')
for s in svcs: print(f\"  {s['name']}: {s['running']}/{s['desired']}\")
")
  echo "$RUNNING"
  if echo "$RUNNING" | grep -q "^YES"; then
    log "All tasks RUNNING!"
    break
  fi
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    die "Timeout waiting for tasks to start. Check ECS service events."
  fi
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

# ─── STEP 11: API GATEWAY ────────────────────────────────────────────────────
log "=== STEP 11: Creating API Gateway HTTP API ==="

API_ID=$(aws apigatewayv2 create-api \
  --name my-app-api \
  --protocol-type HTTP \
  --tags '{"Project":"my-app","Env":"prod"}' \
  --query 'ApiId' --output text --region "$REGION")

INTEG_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "http://$ALB_DNS/{proxy}" \
  --payload-format-version 1.0 \
  --query 'IntegrationId' --output text --region "$REGION")

for RESOURCE in users orders notifications; do
  aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --route-key "ANY /api/v1/$RESOURCE/{proxy+}" \
    --target "integrations/$INTEG_ID" \
    --region "$REGION" > /dev/null
done

aws apigatewayv2 create-stage \
  --api-id "$API_ID" --stage-name prod --auto-deploy \
  --tags '{"Project":"my-app","Env":"prod"}' \
  --region "$REGION" > /dev/null

API_ENDPOINT=$(aws apigatewayv2 get-api \
  --api-id "$API_ID" --query 'ApiEndpoint' --output text --region "$REGION")
log "API Gateway endpoint: $API_ENDPOINT"

# ─── STEP 12: AUTO SCALING ────────────────────────────────────────────────────
log "=== STEP 12: Configuring auto scaling ==="

for SVC in user-service order-service notification-service; do
  aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --resource-id "service/my-app-cluster/$SVC" \
    --scalable-dimension ecs:service:DesiredCount \
    --min-capacity 1 --max-capacity 5 \
    --region "$REGION"

  aws application-autoscaling put-scaling-policy \
    --service-namespace ecs \
    --resource-id "service/my-app-cluster/$SVC" \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name "${SVC}-cpu-scaling" \
    --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration \
      '{"TargetValue":65.0,"PredefinedMetricSpecification":{"PredefinedMetricType":"ECSServiceAverageCPUUtilization"},"ScaleInCooldown":120,"ScaleOutCooldown":30}' \
    --region "$REGION" > /dev/null
  log "Auto scaling configured for $SVC (CPU 65%, 1-5 tasks)"
done

# ─── STEP 13: SMOKE TESTS ─────────────────────────────────────────────────────
log "=== STEP 13: Running smoke tests ==="
sleep 10  # brief settle time

PASS=0; FAIL=0
smoke_test() {
  local URL=$1 LABEL=$2
  HTTP=$(curl -s -o /tmp/resp.json -w "%{http_code}" "$URL")
  BODY=$(cat /tmp/resp.json)
  if [ "$HTTP" = "200" ]; then
    log "PASS [$LABEL] $URL → $BODY"
    PASS=$((PASS+1))
  else
    log "FAIL [$LABEL] $URL → HTTP $HTTP | $BODY"
    FAIL=$((FAIL+1))
  fi
}

smoke_test "http://$ALB_DNS/api/v1/users/health"         "ALB user-service"
smoke_test "http://$ALB_DNS/api/v1/orders/health"        "ALB order-service"
smoke_test "http://$ALB_DNS/api/v1/notifications/health" "ALB notification-service"
smoke_test "$API_ENDPOINT/prod/api/v1/users/health"         "APIGW user-service"
smoke_test "$API_ENDPOINT/prod/api/v1/orders/health"        "APIGW order-service"
smoke_test "$API_ENDPOINT/prod/api/v1/notifications/health" "APIGW notification-service"

# ─── STEP 14: DEPLOYMENT SUMMARY ─────────────────────────────────────────────
log "=== STEP 14: Deployment Summary ==="

SVC_STATUS=$(aws ecs describe-services \
  --cluster my-app-cluster \
  --services user-service order-service notification-service \
  --region "$REGION" \
  --query 'services[*].{name:serviceName,running:runningCount,desired:desiredCount,status:status}' \
  --output table)

cat << SUMMARY

┌─────────────────────────────────────────────────────────────────────────┐
│                        DEPLOYMENT SUMMARY                               │
├─────────────────────────────────────────────────────────────────────────┤
│ Region          : $REGION                                          │
│ Account ID      : $ACCOUNT_ID                                           │
│ VPC ID          : $VPC_ID                                    │
│ ECS Cluster     : my-app-cluster                                        │
│ ALB DNS         : $ALB_DNS
│ API Gateway URL : $API_ENDPOINT
│                                                                         │
│ ECR Images:                                                             │
│   $ECR_BASE/my-app/user-service:latest
│   $ECR_BASE/my-app/order-service:latest
│   $ECR_BASE/my-app/notification-service:latest
│                                                                         │
│ Test Endpoints:                                                         │
│   GET $API_ENDPOINT/prod/api/v1/users/health
│   GET $API_ENDPOINT/prod/api/v1/orders/health
│   GET $API_ENDPOINT/prod/api/v1/notifications/health
│                                                                         │
│ Smoke Tests: $PASS passed, $FAIL failed                                 │
└─────────────────────────────────────────────────────────────────────────┘

$SVC_STATUS
SUMMARY

if [ "$FAIL" -gt 0 ]; then
  log "Some smoke tests failed. Check ECS logs with:"
  log "  aws logs tail /ecs/user-service --follow --region $REGION"
  log "  aws elbv2 describe-target-health --target-group-arn $TG_USER_ARN --region $REGION"
fi
