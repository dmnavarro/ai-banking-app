#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# DG Bank — demo desktop for the Laptop Agents use case (M8)
# Usage: ./deploy-desktop.sh [options]             # create/update the desktop and install the software
#        ./deploy-desktop.sh --setup              # re-run the software setup (e.g. after a key change)
#        ./deploy-desktop.sh --show-code          # print the access code SEs type in the app
#        ./deploy-desktop.sh --rotate-code        # new access code (then re-run deploy-ecs.sh)
#        ./deploy-desktop.sh --start | --stop     # start or stop the instance
#        ./deploy-desktop.sh --connect            # admin fallback: SSM tunnel to localhost:6080
#        ./deploy-desktop.sh --delete             # remove the desktop
#
# What the default run does (in order):
#   1. Check the engineer-laptop virtual key exists in SSM (/dgbank/gateway-key-laptop)
#      and create the desktop access code (/dgbank/desktop-access-code) if there is none
#   2. Read the gateway URLs from the ECS stack (GatewayBaseUrl, GatewayMcpUrl)
#   3. Deploy CloudFormation stack (EC2 instance in the ECS stack's VPC; noVNC open only
#      to the app's security group)
#   4. Wait for the SSM agent, then run desktop/setup.sh on the instance with Run Command:
#      XFCE + TigerVNC + noVNC, Chrome, Open WebUI and Hermes Agent, both using the gateway
#   5. Print the deploy-ecs.sh command that lets the app relay the desktop at /desktop/
#
# SEs open the desktop from the app's Laptop Agents page with the access code; the app
# starts the instance on request and the desktop stops itself after 60 idle minutes.
# ---------------------------------------------------------------------------

STACK_NAME="dgbank-demo-desktop"
ECS_STACK="dgbank-ai-app-demo-ecs"
REGION="ap-southeast-1"
INSTANCE_TYPE="t3.large"
GW_URL=""                             # empty = the ECS stack's GatewayBaseUrl
GW_MCP_URL=""                         # empty = the ECS stack's GatewayMcpUrl
HERMES_MODEL="dgbank-chat"            # model name Hermes asks the gateway for
V1_REGION="sg"
LOCAL_PORT="6080"
MODE="deploy"

usage() {
  cat <<EOF
Usage: $0 [--connect | --setup | --start | --stop | --delete] [options]

Modes:
  (default)            Create or update the desktop and install its software
  --setup              Re-run the software setup on the existing desktop
  --show-code          Print the access code SEs type before the desktop opens
  --rotate-code        Create a new access code (then re-run deploy-ecs.sh so the app picks it up)
  --start / --stop     Start or stop the instance (stopped = no compute cost)
  --connect            Admin fallback: SSM tunnel to the desktop's noVNC on localhost
  --delete             Delete the desktop stack

Optional:
  --region             AWS region (default: ap-southeast-1, must match the ECS stack)
  --ecs-stack          Name of the ECS CF stack (default: dgbank-ai-app-demo-ecs)
  --stack-name         CloudFormation stack name (default: dgbank-demo-desktop)
  --instance-type      t3.large | t3.xlarge | m7i.large (default: t3.large)
  --gateway-url        AI Gateway LLM endpoint (default: from the ECS stack)
  --gateway-mcp-url    AI Gateway MCP Connect URL (default: from the ECS stack)
  --v1-region          Vision One portal region for the bookmark: sg, us, eu, jp, au, in (default: sg)
  --hermes-model       Model name Hermes requests (default: dgbank-chat). Use one whose routing rule
                       sends it to Bedrock, e.g. dgbank-agent: Hermes requests exceed Groq's free tier
  --local-port         Local port for --connect (default: 6080)
  --help               Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --connect)         MODE="connect";            shift ;;
    --setup)           MODE="setup";              shift ;;
    --show-code)       MODE="show-code";          shift ;;
    --rotate-code)     MODE="rotate-code";        shift ;;
    --start)           MODE="start";              shift ;;
    --stop)            MODE="stop";               shift ;;
    --delete)          MODE="delete";             shift ;;
    --region)          REGION="$2";               shift 2 ;;
    --ecs-stack)       ECS_STACK="$2";            shift 2 ;;
    --stack-name)      STACK_NAME="$2";           shift 2 ;;
    --instance-type)   INSTANCE_TYPE="$2";        shift 2 ;;
    --gateway-url)     GW_URL="$2";               shift 2 ;;
    --gateway-mcp-url) GW_MCP_URL="$2";           shift 2 ;;
    --hermes-model)    HERMES_MODEL="$2";         shift 2 ;;
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
  echo "Hermes model: $HERMES_MODEL"
  echo ""
  echo "Installing the desktop software with SSM Run Command (10–15 minutes the first time)..."

  # The script travels base64-encoded so quoting survives Run Command unchanged
  local b64
  b64=$(base64 < "$SETUP_SCRIPT" | tr -d '\n')
  local params
  params=$(jq -n --arg b64 "$b64" --arg gw "$GW_URL" --arg mcp "$GW_MCP_URL" --arg region "$REGION" --arg ev "$v1_events" --arg hm "$HERMES_MODEL" '{
    executionTimeout: ["3600"],
    commands: [
      "echo \($b64) | base64 -d > /root/dgbank-desktop-setup.sh",
      "GW_URL=\($gw | @sh) GW_MCP_URL=\($mcp | @sh) REGION=\($region | @sh) V1_EVENTS=\($ev | @sh) HERMES_MODEL=\($hm | @sh) bash /root/dgbank-desktop-setup.sh"
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

stack_output() {
  aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

new_code() {
  # 12 characters without look-alikes (0/O, 1/l/I), easy to read out on a call
  LC_ALL=C tr -dc 'abcdefghjkmnpqrstuvwxyz23456789' < /dev/urandom | head -c 12
}

show_code() {
  aws ssm get-parameter --region "$REGION" --name /dgbank/desktop-access-code \
    --with-decryption --query Parameter.Value --output text
}

print_connect() {
  local id url
  id=$(instance_id); url=$(stack_output DesktopUrl)
  echo ""
  echo "Let the app relay the desktop (once, and again after --rotate-code):"
  echo "  ./deploy-ecs.sh --desktop-instance-id $id --desktop-url $url"
  echo ""
  echo "SEs: Laptop Agents page → Open demo desktop, access code: $(show_code)"
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
  show-code)
    show_code
    exit 0
    ;;
  rotate-code)
    aws ssm put-parameter --region "$REGION" --name /dgbank/desktop-access-code \
      --type SecureString --overwrite --value "$(new_code)" > /dev/null
    echo "New access code: $(show_code)"
    echo "Re-run ./deploy-ecs.sh (no flags needed) so the app picks it up."
    exit 0
    ;;
  delete)
    echo "Deleting stack $STACK_NAME..."
    aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
    echo "Deleted. The SSM parameters /dgbank/gateway-key-laptop and /dgbank/desktop-access-code are kept."
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

if ! aws ssm get-parameter --name /dgbank/desktop-access-code --region "$REGION" > /dev/null 2>&1; then
  aws ssm put-parameter --region "$REGION" --name /dgbank/desktop-access-code \
    --type SecureString --value "$(new_code)" > /dev/null
  echo "Created the desktop access code (/dgbank/desktop-access-code)."
fi

VPC_ID=$(aws cloudformation describe-stack-resource --stack-name "$ECS_STACK" --logical-resource-id VPC \
  --region "$REGION" --query StackResourceDetail.PhysicalResourceId --output text)
SUBNET_ID=$(aws cloudformation describe-stack-resource --stack-name "$ECS_STACK" --logical-resource-id PublicSubnetA \
  --region "$REGION" --query StackResourceDetail.PhysicalResourceId --output text)
APP_SG_ID=$(aws cloudformation describe-stack-resource --stack-name "$ECS_STACK" --logical-resource-id ECSInstanceSecurityGroup \
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
  --parameter-overrides VpcId="$VPC_ID" SubnetId="$SUBNET_ID" AppSecurityGroupId="$APP_SG_ID" InstanceType="$INSTANCE_TYPE"

ID=$(instance_id)
echo "Instance    : $ID"
aws ec2 start-instances --region "$REGION" --instance-ids "$ID" > /dev/null 2>&1 || true
aws ec2 wait instance-running --region "$REGION" --instance-ids "$ID"
wait_for_ssm "$ID"
run_setup "$ID"
print_connect
