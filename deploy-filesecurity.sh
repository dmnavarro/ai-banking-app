#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# DG Bank — Vision One File Security bucket setup
# Usage: ./deploy-filesecurity.sh [--region <region>] [--ecs-stack <name>]
#
# What this does:
#   1. Deploys cloudformation/filesecurity-buckets.yaml
#      (creates scanning + quarantine S3 buckets and IAM policy)
#   2. Attaches the IAM policy to the ECS task role
#   3. Prints next steps for Vision One and ECS redeployment
# ---------------------------------------------------------------------------

REGION="${AWS_REGION:-ap-southeast-1}"
ECS_STACK="dgbank-ai-app-demo-ecs"
FS_STACK="dgbank-filesecurity"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/cloudformation/filesecurity-buckets.yaml"
TASK_ROLE_NAME="dgbank-ai-app-demo-ecs-task-role"

while [[ $# -gt 0 ]]; do
  case $1 in
    --region)    REGION="$2";    shift 2 ;;
    --ecs-stack) ECS_STACK="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo ""
echo "▶  Deploying File Security buckets (stack: $FS_STACK, region: $REGION)..."
aws cloudformation deploy \
  --template-file "$TEMPLATE" \
  --stack-name "$FS_STACK" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION"

# ── Read outputs ────────────────────────────────────────────────────────────
get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$FS_STACK" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

SCANNING_BUCKET=$(get_output ScanningBucketName)
QUARANTINE_BUCKET=$(get_output QuarantineBucketName)
POLICY_ARN=$(get_output FileScanPolicyArn)

echo ""
echo "✅  Buckets created:"
echo "    Scanning:   $SCANNING_BUCKET"
echo "    Quarantine: $QUARANTINE_BUCKET"
echo ""

# ── Attach IAM policy to ECS task role ──────────────────────────────────────
echo "▶  Attaching File Security S3 policy to ECS task role ($TASK_ROLE_NAME)..."
if aws iam attach-role-policy \
     --role-name "$TASK_ROLE_NAME" \
     --policy-arn "$POLICY_ARN" 2>/dev/null; then
  echo "✅  Policy attached."
else
  echo "⚠️   Could not attach policy automatically."
  echo "    Manually run:"
  echo "    aws iam attach-role-policy --role-name $TASK_ROLE_NAME --policy-arn $POLICY_ARN"
fi

# ── Next steps ───────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo " NEXT STEPS"
echo "════════════════════════════════════════════════════════"
echo ""
echo " 1. Vision One — File Security → Storage"
echo "    a. Add scanning bucket : $SCANNING_BUCKET"
echo "    b. Add quarantine bucket: $QUARANTINE_BUCKET"
echo "    c. Enable the scanning rule"
echo ""
echo " 2. Redeploy ECS — the CI pipeline computes the bucket name"
echo "    automatically from your AWS account ID + region and injects"
echo "    it into ECS. Just push any commit to trigger a deploy:"
echo ""
echo "    git commit --allow-empty -m 'redeploy for file security'"
echo "    git push"
echo ""
echo "════════════════════════════════════════════════════════"
