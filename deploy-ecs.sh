#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Trend Bank — ECS on EC2 deploy script
# Usage: ./deploy-ecs.sh --github-org <org> [options]
# ---------------------------------------------------------------------------

STACK_NAME="dgbank-ai-app-demo-ecs"
REGION="ap-southeast-1"
INSTANCE_TYPE="t3.small"
BEDROCK_REGION="ap-southeast-1"
BEDROCK_MODEL_ID="anthropic.claude-3-haiku-20240307-v1:0"
CREATE_OIDC="true"
GITHUB_ORG=""
GITHUB_REPO="ai-banking-app"
CERTIFICATE_ARN=""

usage() {
  cat <<EOF
Usage: $0 --github-org <org> [options]

Required:
  --github-org       GitHub username or organization name

Optional:
  --github-repo      GitHub repository name (default: ai-banking-app)
  --region           AWS region (default: ap-southeast-1)
  --instance-type    EC2 instance type (default: t3.small)
  --bedrock-region   Bedrock API region (default: ap-southeast-1)
  --bedrock-model    Bedrock model ID (default: anthropic.claude-3-haiku-20240307-v1:0)
  --certificate-arn  ACM certificate ARN for HTTPS (optional)
  --skip-oidc        Skip GitHub OIDC provider creation if it already exists
  --stack-name       CloudFormation stack name (default: dgbank-ai-app-demo-ecs)
  --help             Show this help
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --github-org)      GITHUB_ORG="$2";        shift 2 ;;
    --github-repo)     GITHUB_REPO="$2";       shift 2 ;;
    --region)          REGION="$2";            shift 2 ;;
    --instance-type)   INSTANCE_TYPE="$2";     shift 2 ;;
    --bedrock-region)  BEDROCK_REGION="$2";    shift 2 ;;
    --bedrock-model)   BEDROCK_MODEL_ID="$2";  shift 2 ;;
    --certificate-arn) CERTIFICATE_ARN="$2";   shift 2 ;;
    --skip-oidc)       CREATE_OIDC="false";    shift ;;
    --stack-name)      STACK_NAME="$2";        shift 2 ;;
    --help)          usage ;;
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
# Check prerequisites
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
echo "AWS account : $ACCOUNT_ID"
echo "Region      : $REGION"
echo "GitHub org  : $GITHUB_ORG/$GITHUB_REPO"
echo ""

# ---------------------------------------------------------------------------
# Deploy CloudFormation stack
# ---------------------------------------------------------------------------
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
    CertificateArn="$CERTIFICATE_ARN" || true

# Verify the stack is actually in a healthy state
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

ECR_URI=$(get_output "ECRRepositoryUri")
APP_URL=$(get_output "AppURL")
ALB_DNS=$(get_output "ALBDNSName")
GITHUB_ROLE=$(get_output "GitHubActionsRoleArn")
ECS_CLUSTER=$(get_output "ECSClusterName")
ECS_SERVICE=$(get_output "ECSServiceName")

echo "ECR URI     : $ECR_URI"
echo "App URL     : $APP_URL"
echo ""

# ---------------------------------------------------------------------------
# Build and push Docker image
# ---------------------------------------------------------------------------
echo "Logging in to ECR..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

echo "Building Docker image..."
docker build -t dgbank-ai-app-demo "$SCRIPT_DIR"

echo "Tagging and pushing image..."
docker tag dgbank-ai-app-demo:latest "$ECR_URI:latest"
docker push "$ECR_URI:latest"
echo "Image pushed."
echo ""

# ---------------------------------------------------------------------------
# Force ECS redeployment to pick up the new image
# ---------------------------------------------------------------------------
echo "Triggering ECS redeployment..."
aws ecs update-service \
  --cluster "$ECS_CLUSTER" \
  --service "$ECS_SERVICE" \
  --force-new-deployment \
  --region "$REGION" \
  --output text --query "service.serviceName" > /dev/null

echo "Waiting for service to stabilize (this takes ~2 minutes)..."
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
echo "DNS — point your domain CNAME to:"
echo "  $ALB_DNS"
echo ""
echo "GitHub Actions secret to add:"
echo "  AWS_ROLE_ARN = $GITHUB_ROLE"
echo ""
