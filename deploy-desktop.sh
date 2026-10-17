#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# DG Bank — demo desktop for the Laptop Agents use case (M8)
# Usage: ./deploy-desktop.sh [options]             # create/update the desktop and install the software
#        ./deploy-desktop.sh --connect            # open the SSM tunnel; then browse to the printed URL
#        ./deploy-desktop.sh --setup              # re-run the software setup (e.g. after a key change)
#        ./deploy-desktop.sh --start | --stop     # start or stop the instance between demos
#        ./deploy-desktop.sh --delete             # remove the desktop
#
# What the default run does (in order):
#   1. Check the engineer-laptop virtual key exists in SSM (/dgbank/gateway-key-laptop)
#   2. Read the gateway URLs from the ECS stack (GatewayBaseUrl, GatewayMcpUrl)
#   3. Deploy CloudFormation stack (EC2 instance in the ECS stack's VPC, no inbound ports)
#   4. Wait for the SSM agent, then run desktop/setup.sh on the instance with Run Command:
#      XFCE + TigerVNC + noVNC, Chrome, Open WebUI and Hermes Agent, both using the gateway
#
# The desktop is reached only through an SSM port-forward (needs the Session Manager
# plugin for the AWS CLI on your machine).
# ---------------------------------------------------------------------------

STACK_NAME="dgbank-demo-desktop"
ECS_STACK="dgbank-ai-app-demo-ecs"
REGION="ap-southeast-1"
INSTANCE_TYPE="t3.large"
GW_URL=""                             # empty = the ECS stack's GatewayBaseUrl
GW_MCP_URL=""                         # empty = the ECS stack's GatewayMcpUrl
V1_REGION="sg"
LOCAL_PORT="6080"
MODE="deploy"

usage() {
  cat <<EOF
Usage: $0 [--connect | --setup | --start | --stop | --delete] [options]

Modes:
  (default)            Create or update the desktop and install its software
  --connect            Open the SSM tunnel to the desktop (leave it running during the demo)
  --setup              Re-run the software setup on the existing desktop
  --start / --stop     Start or stop the instance (stopped = no compute cost)
  --delete             Delete the desktop stack

Optional:
  --region             AWS region (default: ap-southeast-1, must match the ECS stack)
  --ecs-stack          Name of the ECS CF stack (default: dgbank-ai-app-demo-ecs)
  --stack-name         CloudFormation stack name (default: dgbank-demo-desktop)
  --instance-type      t3.large | t3.xlarge | m7i.large (default: t3.large)
  --gateway-url        AI Gateway LLM endpoint (default: from the ECS stack)
  --gateway-mcp-url    AI Gateway MCP Connect URL (default: from the ECS stack)
  --v1-region          Vision One portal region for the bookmark: sg, us, eu, jp, au, in (default: sg)
  --local-port         Local port for --connect (default: 6080)
  --help               Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --connect)         MODE="connect";            shift ;;
    --setup)           MODE="setup";              shift ;;
    --start)           MODE="start";              shift ;;
    --stop)            MODE="stop";               shift ;;
    --delete)          MODE="delete";             shift ;;
    --region)          REGION="$2";               shift 2 ;;
    --ecs-stack)       ECS_STACK="$2";            shift 2 ;;
    --stack-name)      STACK_NAME="$2";           shift 2 ;;
    --instance-type)   INSTANCE_TYPE="$2";        shift 2 ;;
    --gateway-url)     GW_URL="$2";               shift 2 ;;
    --gateway-mcp-url) GW_MCP_URL="$2";           shift 2 ;;
    --v1-region)       V1_REGION="$2";            shift 2 ;;
    --local-port)      LOCAL_PORT="$2";           shift 2 ;;
    --help)            usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/cloudformation/desktop.yml"
SETUP_SCRIPT="$SCRIPT_DIR/desktop/setup.sh"

for cmd in aws jq base64; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is not installed or not in PATH"
    exit 1
  fi
done

instance_id() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text 2>/dev/null || true
}

ecs_param() {
  aws cloudformation describe-stacks --stack-name "$ECS_STACK" --region "$REGION" \
    --query "Stacks[0].Parameters[?ParameterKey=='$1'].ParameterValue" --output text
}

wait_for_ssm() {
  echo "Waiting for the SSM agent on $1..."
  for _ in $(seq 1 60); do
    STATUS=$(aws ssm describe-instance-information --region "$REGION" \
      --filters "Key=InstanceIds,Values=$1" --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null || true)
    [[ "$STATUS" == "Online" ]] && return 0
    sleep 10
  done
  echo "Error: the SSM agent did not come online within 10 minutes."
  exit 1
}

run_setup() {
  local id="$1"
  [[ -z "$GW_URL" ]] && GW_URL=$(ecs_param GatewayBaseUrl)
  [[ -z "$GW_MCP_URL" ]] && GW_MCP_URL=$(ecs_param GatewayMcpUrl)
  [[ "$GW_URL" == "None" ]] && GW_URL=""
  [[ "$GW_MCP_URL" == "None" ]] && GW_MCP_URL=""
  if [[ -z "$GW_URL" ]]; then
    echo "Error: no gateway URL. Pass --gateway-url, or deploy the ECS stack with --gateway-url first."
    exit 1
  fi
  local v1_host="portal.${V1_REGION}.xdr.trendmicro.com"
  [[ "$V1_REGION" == "us" ]] && v1_host="portal.xdr.trendmicro.com"
  local v1_events="https://${v1_host}/index.html#/app/ai-app-sec?path=%2Fgateway%2Fevents"

  echo "Gateway     : $GW_URL"
  echo "MCP         : ${GW_MCP_URL:-(none: Hermes gets no banking tools)}"
  echo ""
  echo "Installing the desktop software with SSM Run Command (10–15 minutes the first time)..."

  # The script travels base64-encoded so quoting survives Run Command unchanged
  local b64
  b64=$(base64 < "$SETUP_SCRIPT" | tr -d '\n')
  local params
  params=$(jq -n --arg b64 "$b64" --arg gw "$GW_URL" --arg mcp "$GW_MCP_URL" --arg region "$REGION" --arg ev "$v1_events" '{
    executionTimeout: ["3600"],
    commands: [
      "echo \($b64) | base64 -d > /root/dgbank-desktop-setup.sh",
      "GW_URL=\($gw | @sh) GW_MCP_URL=\($mcp | @sh) REGION=\($region | @sh) V1_EVENTS=\($ev | @sh) bash /root/dgbank-desktop-setup.sh"
    ]}')
  local cmd_id
  cmd_id=$(aws ssm send-command --region "$REGION" --instance-ids "$id" \
    --document-name AWS-RunShellScript --comment "DG Bank demo desktop setup" \
    --parameters "$params" --query Command.CommandId --output text)

  local status="Pending"
  while [[ "$status" == "Pending" || "$status" == "InProgress" || "$status" == "Delayed" ]]; do
    sleep 20
    status=$(aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" --instance-id "$id" \
      --query Status --output text 2>/dev/null || echo Pending)
    echo "  setup: $status"
  done
  aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" --instance-id "$id" \
    --query StandardOutputContent --output text | tail -n 15
  if [[ "$status" != "Success" ]]; then
    echo ""
    echo "Setup failed. Errors:"
    aws ssm get-command-invocation --region "$REGION" --command-id "$cmd_id" --instance-id "$id" \
      --query StandardErrorContent --output text | tail -n 25
    exit 1
  fi
}

print_connect() {
  echo ""
  echo "Open the desktop:"
  echo "  ./deploy-desktop.sh --connect      (leave it running)"
  echo "  then browse to http://localhost:${LOCAL_PORT}/vnc.html?autoconnect=1&resize=scale"
}

case "$MODE" in
  connect)
    ID=$(instance_id)
    [[ -z "$ID" || "$ID" == "None" ]] && { echo "Error: no desktop. Run ./deploy-desktop.sh first."; exit 1; }
    if ! command -v session-manager-plugin &>/dev/null; then
      echo "Error: the Session Manager plugin for the AWS CLI is not installed."
      echo "  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
      exit 1
    fi
    echo "Desktop: http://localhost:${LOCAL_PORT}/vnc.html?autoconnect=1&resize=scale"
    echo "(Ctrl+C closes the tunnel)"
    exec aws ssm start-session --region "$REGION" --target "$ID" \
      --document-name AWS-StartPortForwardingSession \
      --parameters "portNumber=6080,localPortNumber=${LOCAL_PORT}"
    ;;
  start|stop)
    ID=$(instance_id)
    [[ -z "$ID" || "$ID" == "None" ]] && { echo "Error: no desktop. Run ./deploy-desktop.sh first."; exit 1; }
    if [[ "$MODE" == "start" ]]; then
      aws ec2 start-instances --region "$REGION" --instance-ids "$ID" > /dev/null
      aws ec2 wait instance-running --region "$REGION" --instance-ids "$ID"
      wait_for_ssm "$ID"
      echo "Desktop running."
      print_connect
    else
      aws ec2 stop-instances --region "$REGION" --instance-ids "$ID" > /dev/null
      echo "Stopping $ID. Start it again with ./deploy-desktop.sh --start"
    fi
    exit 0
    ;;
  delete)
    echo "Deleting stack $STACK_NAME..."
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
    echo "Deleted. The SSM parameter /dgbank/gateway-key-laptop is kept."
    exit 0
    ;;
  setup)
    ID=$(instance_id)
    [[ -z "$ID" || "$ID" == "None" ]] && { echo "Error: no desktop. Run ./deploy-desktop.sh first."; exit 1; }
    wait_for_ssm "$ID"
    run_setup "$ID"
    print_connect
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# Default: create/update the stack, then install the software
# ---------------------------------------------------------------------------
if ! aws ssm get-parameter --name /dgbank/gateway-key-laptop --region "$REGION" > /dev/null 2>&1; then
  echo "Error: SSM parameter /dgbank/gateway-key-laptop not found."
  echo "Create the engineer-laptop identity and virtual key in the Vision One console, then:"
  echo "  aws ssm put-parameter --name /dgbank/gateway-key-laptop --type SecureString --value '<virtual key>' --region $REGION"
  exit 1
fi

VPC_ID=$(aws cloudformation describe-stack-resource --stack-name "$ECS_STACK" --logical-resource-id VPC \
  --region "$REGION" --query StackResourceDetail.PhysicalResourceId --output text)
SUBNET_ID=$(aws cloudformation describe-stack-resource --stack-name "$ECS_STACK" --logical-resource-id PublicSubnetA \
  --region "$REGION" --query StackResourceDetail.PhysicalResourceId --output text)

echo "Region      : $REGION"
echo "VPC         : $VPC_ID ($SUBNET_ID)"
echo "Instance    : $INSTANCE_TYPE"
echo ""
echo "Deploying stack $STACK_NAME..."
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --region "$REGION" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides VpcId="$VPC_ID" SubnetId="$SUBNET_ID" InstanceType="$INSTANCE_TYPE"

ID=$(instance_id)
echo "Instance    : $ID"
aws ec2 start-instances --region "$REGION" --instance-ids "$ID" > /dev/null 2>&1 || true
aws ec2 wait instance-running --region "$REGION" --instance-ids "$ID"
wait_for_ssm "$ID"
run_setup "$ID"
print_connect
