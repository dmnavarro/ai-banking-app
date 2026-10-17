#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# DG Bank — ECS on EC2 deploy script
# Usage: ./deploy-ecs.sh --github-org <org> [options]
#
# What this script does (in order):
#   1. Create ECR repo if it doesn't exist
#   2. Build & push Docker image (linux/amd64)
#   3. Deploy CloudFormation stack (VPC, ECS, ALB, IAM, OIDC)
#   4. Wait for ECS service to stabilize
#   5. Print App URL, DNS target, and GitHub Actions role ARN
# ---------------------------------------------------------------------------

STACK_NAME="dgbank-ai-app-demo-ecs"
ECR_REPO="dgbank-ai-app-demo"
REGION="ap-southeast-1"
INSTANCE_TYPE="t3.small"
BEDROCK_REGION="us-east-1"
BEDROCK_MODEL_ID="us.deepseek.r1-v1:0"
CREATE_OIDC="true"
GITHUB_ORG=""
GITHUB_REPO="ai-banking-app"
CERTIFICATE_ARN=""
GATEWAY_URL=""
DIRECT_LLM_URL=""
DIRECT_LLM_MODEL=""

usage() {
  cat <<EOF
Usage: $0 --github-org <org> [options]

Required:
  --github-org       GitHub username or organization name

Optional:
  --github-repo      GitHub repository name (default: ai-banking-app)
  --region           AWS region (default: ap-southeast-1)
  --instance-type    EC2 instance type (default: t3.small)
  --bedrock-region   Bedrock API region (default: us-east-1)
  --bedrock-model    Bedrock model ID (default: us.deepseek.r1-v1:0)
  --certificate-arn  ACM certificate ARN for HTTPS (optional)
  --gateway-url      AI Gateway LLM endpoint from deploy-gateway.sh --expose (optional)
  --direct-llm-url   OpenAI-compatible base URL for the no-gateway route, e.g. https://api.groq.com/openai
  --direct-llm-model Model ID for --direct-llm-url, e.g. openai/gpt-oss-120b
  --skip-oidc        Skip GitHub OIDC provider creation if it already exists
  --stack-name       CloudFormation stack name (default: dgbank-ai-app-demo-ecs)
  --help             Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --github-org)      GITHUB_ORG="$2";        shift 2 ;;
    --github-repo)     GITHUB_REPO="$2";       shift 2 ;;
    --region)          REGION="$2";            shift 2 ;;
    --instance-type)   INSTANCE_TYPE="$2";     shift 2 ;;
    --bedrock-region)  BEDROCK_REGION="$2";    shift 2 ;;
    --bedrock-model)   BEDROCK_MODEL_ID="$2";  shift 2 ;;
    --certificate-arn) CERTIFICATE_ARN="$2";  shift 2 ;;
    --gateway-url)     GATEWAY_URL="$2";       shift 2 ;;
    --direct-llm-url)  DIRECT_LLM_URL="$2";    shift 2 ;;
    --direct-llm-model) DIRECT_LLM_MODEL="$2"; shift 2 ;;
    --skip-oidc)       CREATE_OIDC="false";    shift ;;
    --stack-name)      STACK_NAME="$2";        shift 2 ;;
    --help)            usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$GITHUB_ORG" ]]; then
  echo "Error: --github-org is required"
  usage
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/cloudformation/ecs.yml"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
echo ""
echo "Checking prerequisites..."
for cmd in aws docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is not installed or not in PATH"
    exit 1
  fi
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO"

echo "AWS account : $ACCOUNT_ID"
echo "Region      : $REGION"
echo "GitHub org  : $GITHUB_ORG/$GITHUB_REPO"
echo "ECR repo    : $ECR_URI"
echo ""

# ---------------------------------------------------------------------------
# AI Gateway keys must exist before the task definition references them,
# otherwise the ECS task fails to start
# ---------------------------------------------------------------------------
if [[ -n "$GATEWAY_URL" ]]; then
  for param in /dgbank/gateway-key-assistant /dgbank/gateway-key-ops; do
    if ! aws ssm get-parameter --name "$param" --region "$REGION" > /dev/null 2>&1; then
      echo "Error: SSM parameter $param not found (required with --gateway-url)."
      echo "Create it with:"
      echo "  aws ssm put-parameter --name $param --type SecureString --value '<virtual key>' --region $REGION"
      exit 1
    fi
  done
  echo "AI Gateway  : $GATEWAY_URL (keys found in SSM)"
  echo ""
fi

if [[ -n "$DIRECT_LLM_URL" ]]; then
  if [[ -z "$DIRECT_LLM_MODEL" ]]; then
    echo "Error: --direct-llm-model is required with --direct-llm-url"
    exit 1
  fi
  if ! aws ssm get-parameter --name /dgbank/direct-llm-key --region "$REGION" > /dev/null 2>&1; then
    echo "Error: SSM parameter /dgbank/direct-llm-key not found (required with --direct-llm-url)."
    echo "Create it with:"
    echo "  aws ssm put-parameter --name /dgbank/direct-llm-key --type SecureString --value '<provider API key>' --region $REGION"
    exit 1
  fi
  echo "Direct model: $DIRECT_LLM_MODEL at $DIRECT_LLM_URL (key found in SSM)"
  echo ""
fi

# ---------------------------------------------------------------------------
# Step 1 — Ensure ECR repository exists
# ---------------------------------------------------------------------------
echo "Ensuring ECR repository exists..."
aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" > /dev/null 2>&1 || \
  aws ecr create-repository \
    --repository-name "$ECR_REPO" \
    --region "$REGION" \
    --image-scanning-configuration scanOnPush=true > /dev/null
echo "ECR repository ready."
echo ""

# ---------------------------------------------------------------------------
# Step 2 — Build and push Docker image
# ---------------------------------------------------------------------------
echo "Logging in to ECR..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

echo "Building Docker image (linux/amd64)..."
docker build --platform linux/amd64 -t "$ECR_REPO" "$SCRIPT_DIR"

echo "Pushing image to ECR..."
docker tag "$ECR_REPO:latest" "$ECR_URI:latest"
docker push "$ECR_URI:latest"
echo "Image pushed."
echo ""

# ---------------------------------------------------------------------------
# Step 3 — Deploy CloudFormation stack
# ---------------------------------------------------------------------------
# Only pass the certificate / gateway / direct-model settings when their flags are
# given, so a later run without them keeps the values already on the stack (an empty
# CertificateArn would otherwise remove the HTTPS listener)
GATEWAY_OVERRIDE=()
[[ -n "$CERTIFICATE_ARN" ]] && GATEWAY_OVERRIDE+=(CertificateArn="$CERTIFICATE_ARN")
[[ -n "$GATEWAY_URL" ]] && GATEWAY_OVERRIDE+=(GatewayBaseUrl="$GATEWAY_URL")
[[ -n "$DIRECT_LLM_URL" ]] && GATEWAY_OVERRIDE+=(DirectLlmBaseUrl="$DIRECT_LLM_URL" DirectLlmModel="$DIRECT_LLM_MODEL")

echo "Deploying CloudFormation stack: $STACK_NAME ..."
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    GitHubOrg="$GITHUB_ORG" \
    GitHubRepo="$GITHUB_REPO" \
    CreateOIDCProvider="$CREATE_OIDC" \
    InstanceType="$INSTANCE_TYPE" \
    BedrockRegion="$BEDROCK_REGION" \
    BedrockModelId="$BEDROCK_MODEL_ID" \
    ${GATEWAY_OVERRIDE[@]+"${GATEWAY_OVERRIDE[@]}"} || true

STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].StackStatus" --output text)

if [[ "$STACK_STATUS" != *"COMPLETE" ]]; then
  echo "Error: Stack is in unexpected state: $STACK_STATUS"
  echo "Run: aws cloudformation describe-stack-events --stack-name $STACK_NAME --region $REGION"
  exit 1
fi
echo "Stack status: $STACK_STATUS"
echo ""

# ---------------------------------------------------------------------------
# Get stack outputs
# ---------------------------------------------------------------------------
get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

APP_URL=$(get_output "AppURL")
ALB_DNS=$(get_output "ALBDNSName")
GITHUB_ROLE=$(get_output "GitHubActionsRoleArn")
ECS_CLUSTER=$(get_output "ECSClusterName")
ECS_SERVICE=$(get_output "ECSServiceName")

# ---------------------------------------------------------------------------
# Step 4 — Force ECS service to pick up the new image
# ---------------------------------------------------------------------------
echo "Triggering ECS redeployment..."
aws ecs update-service \
  --cluster "$ECS_CLUSTER" \
  --service "$ECS_SERVICE" \
  --force-new-deployment \
  --region "$REGION" \
  --output text --query "service.serviceName" > /dev/null

echo "Waiting for service to stabilize (~2 minutes)..."
aws ecs wait services-stable \
  --cluster "$ECS_CLUSTER" \
  --services "$ECS_SERVICE" \
  --region "$REGION"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "================================================="
echo "  DG Bank is live!"
echo "  $APP_URL"
echo "================================================="
echo ""
echo "Next steps:"
echo ""
echo "1. DNS — set this CNAME at your DNS provider:"
echo "   bank.hawkins.global  →  $ALB_DNS"
echo ""
echo "2. GitHub Actions — add this secret to your repo:"
echo "   AWS_ROLE_ARN = $GITHUB_ROLE"
echo "   (Settings → Secrets and variables → Actions → New repository secret)"
echo ""
echo "3. Push to main — GitHub Actions will auto-deploy on every push."
echo ""
