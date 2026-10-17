#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# DG Bank — EKS cluster for TrendAI AI Gateway
# Usage: ./deploy-gateway.sh [options]            # create/update the cluster
#        ./deploy-gateway.sh --expose [options]   # after the Helm install
#        ./deploy-gateway.sh --deploy-mcp [options] # build + deploy the DG Bank MCP server
#        ./deploy-gateway.sh --delete [options]   # tear everything down
#
# What the default run does (in order):
#   1. Look up the VPC and public subnets from the ECS stack
#   2. Create the IAM policy for the AWS Load Balancer Controller
#   3. Deploy CloudFormation stack (EKS cluster, node group, IAM)
#   4. Point kubectl at the cluster and wait for the node
#   5. Install the AWS Load Balancer Controller (public Helm chart)
#   6. Install the Amazon EBS CSI driver with a default gp3 StorageClass
#      (the gateway's bundled Redis stores its data on a persistent volume)
#   7. Print the manual step: run the Helm command from the Vision One console
#
# --expose finds the gateway's Service (Helm release "trendai-gateway") and
# puts an internal Network Load Balancer in front of it, so the ECS app can
# reach it at a stable private address. Run it after the console Helm install.
# ---------------------------------------------------------------------------

STACK_NAME="dgbank-ai-gateway-eks"
ECS_STACK="dgbank-ai-app-demo-ecs"
REGION="ap-southeast-1"
CLUSTER_NAME="dgbank-ai-gateway"
NODE_INSTANCE_TYPE="c7i.xlarge"
NODE_COUNT="1"
K8S_VERSION=""
PUBLIC_ACCESS_CIDR="0.0.0.0/0"
LBC_CHART_VERSION=""                  # empty = latest eks/aws-load-balancer-controller chart
EBS_CSI_CHART_VERSION=""              # empty = latest aws-ebs-csi-driver chart
GATEWAY_RELEASE="trendai-gateway"
GATEWAY_SERVICE=""                    # namespace/name, overrides auto-discovery in --expose
LB_SERVICE_NAME="dgbank-ai-gateway-internal"
MCP_PUBLIC_CERT=""                    # ACM cert ARN: also expose the MCP server publicly over HTTPS
MODE="deploy"

usage() {
  cat <<EOF
Usage: $0 [--expose | --delete] [options]

Modes:
  (default)            Create or update the EKS cluster and install the AWS Load Balancer Controller
  --expose             After the console Helm install: add an internal NLB in front of the gateway
  --deploy-mcp         Build the DG Bank MCP server (mcp/), push it to ECR and run it in the cluster
  --delete             Remove the internal NLB, the gateway release and the EKS stack

Optional:
  --region             AWS region (default: ap-southeast-1, must match the ECS stack)
  --ecs-stack          Name of the ECS CF stack (default: dgbank-ai-app-demo-ecs)
  --stack-name         CloudFormation stack name (default: dgbank-ai-gateway-eks)
  --cluster-name       EKS cluster name (default: dgbank-ai-gateway)
  --instance-type      Node instance type (default: c7i.xlarge)
  --node-count         Number of nodes (default: 1)
  --k8s-version        Kubernetes version, e.g. 1.34 (default: current EKS default)
  --api-cidr           CIDR allowed to reach the Kubernetes API (default: 0.0.0.0/0)
  --gateway-service    namespace/name of the gateway Service, if --expose can't find it
  --mcp-public-cert    With --deploy-mcp: ACM certificate ARN; adds an internet-facing HTTPS
                       load balancer so the console's MCP tool discovery can reach the server
  --help               Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --expose)          MODE="expose";             shift ;;
    --deploy-mcp)      MODE="deploy-mcp";         shift ;;
    --delete)          MODE="delete";             shift ;;
    --region)          REGION="$2";               shift 2 ;;
    --ecs-stack)       ECS_STACK="$2";            shift 2 ;;
    --stack-name)      STACK_NAME="$2";           shift 2 ;;
    --cluster-name)    CLUSTER_NAME="$2";         shift 2 ;;
    --instance-type)   NODE_INSTANCE_TYPE="$2";   shift 2 ;;
    --node-count)      NODE_COUNT="$2";           shift 2 ;;
    --k8s-version)     K8S_VERSION="$2";          shift 2 ;;
    --api-cidr)        PUBLIC_ACCESS_CIDR="$2";   shift 2 ;;
    --gateway-service) GATEWAY_SERVICE="$2";      shift 2 ;;
    --mcp-public-cert) MCP_PUBLIC_CERT="$2";      shift 2 ;;
    --help)            usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/cloudformation/gateway-eks.yml"
LBC_POLICY_NAME="${CLUSTER_NAME}-lbc-policy"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
echo ""
echo "Checking prerequisites..."
REQUIRED=(aws kubectl helm jq curl)
[[ "$MODE" == "deploy-mcp" ]] && REQUIRED+=(docker openssl)
for cmd in "${REQUIRED[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is not installed or not in PATH"
    exit 1
  fi
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "AWS account : $ACCOUNT_ID"
echo "Region      : $REGION"
echo "Cluster     : $CLUSTER_NAME"
echo ""

stack_resource() {
  aws cloudformation describe-stack-resource \
    --stack-name "$ECS_STACK" \
    --logical-resource-id "$1" \
    --region "$REGION" \
    --query "StackResourceDetail.PhysicalResourceId" \
    --output text
}

get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
    --output text
}

use_cluster() {
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" > /dev/null
}

# ---------------------------------------------------------------------------
# --expose — internal NLB in front of the gateway Service
# ---------------------------------------------------------------------------
if [[ "$MODE" == "expose" ]]; then
  use_cluster

  if [[ -n "$GATEWAY_SERVICE" ]]; then
    GW_NS="${GATEWAY_SERVICE%%/*}"
    GW_SVC="${GATEWAY_SERVICE##*/}"
  else
    echo "Looking for the gateway Service (Helm release: $GATEWAY_RELEASE)..."
    MATCHES=$(kubectl get svc -A -l "app.kubernetes.io/instance=$GATEWAY_RELEASE" -o json \
      | jq -r --arg skip "$LB_SERVICE_NAME" '.items[]
          | select(.spec.selector != null and .metadata.name != $skip)
          | select(.metadata.labels["app.kubernetes.io/component"] != "redis")
          | select(.metadata.name | test("redis") | not)
          | "\(.metadata.namespace)/\(.metadata.name)"')
    COUNT=$(printf '%s' "$MATCHES" | grep -c . || true)
    if [[ "$COUNT" -ne 1 ]]; then
      echo "Error: expected one gateway Service, found $COUNT:"
      [[ -n "$MATCHES" ]] && printf '%s\n' "$MATCHES" | sed 's/^/  /'
      echo "List them with: kubectl get svc -A"
      echo "Then rerun with: $0 --expose --gateway-service <namespace>/<name>"
      exit 1
    fi
    GW_NS="${MATCHES%%/*}"
    GW_SVC="${MATCHES##*/}"
  fi
  echo "Gateway Service: $GW_NS/$GW_SVC"

  VPC_CIDR=$(aws ec2 describe-vpcs \
    --vpc-ids "$(get_output VpcId)" --region "$REGION" \
    --query "Vpcs[0].CidrBlock" --output text)

  # Copy the gateway Service's selector and ports into a LoadBalancer Service.
  # The AWS Load Balancer Controller turns it into an internal NLB that only
  # accepts traffic from inside the VPC. The manager port (readiness/admin)
  # stays cluster-internal; the app only needs the LLM and MCP proxy ports.
  kubectl get svc "$GW_SVC" -n "$GW_NS" -o json | jq \
    --arg name "$LB_SERVICE_NAME" --arg cidr "$VPC_CIDR" '{
      apiVersion: "v1",
      kind: "Service",
      metadata: {
        name: $name,
        namespace: .metadata.namespace,
        annotations: {
          "service.beta.kubernetes.io/aws-load-balancer-type": "external",
          "service.beta.kubernetes.io/aws-load-balancer-scheme": "internal",
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type": "ip"
        }
      },
      spec: {
        type: "LoadBalancer",
        selector: .spec.selector,
        loadBalancerSourceRanges: [$cidr],
        ports: [.spec.ports[] | select(.name != "manager") | {name, port, targetPort, protocol}]
      }
    }' | kubectl apply -f -

  echo "Waiting for the internal load balancer address (~2 minutes)..."
  LB_HOST=""
  for _ in $(seq 1 40); do
    LB_HOST=$(kubectl get svc "$LB_SERVICE_NAME" -n "$GW_NS" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [[ -n "$LB_HOST" ]] && break
    sleep 6
  done
  if [[ -z "$LB_HOST" ]]; then
    echo "Error: no load balancer address yet. Check: kubectl describe svc $LB_SERVICE_NAME -n $GW_NS"
    exit 1
  fi

  echo ""
  echo "================================================="
  echo "  AI Gateway is reachable inside the VPC at:"
  kubectl get svc "$LB_SERVICE_NAME" -n "$GW_NS" -o json \
    | jq -r --arg h "$LB_HOST" '.spec.ports[] | "  \($h):\(.port)  (\(.name // "port"))"'
  echo "================================================="
  echo ""
  echo "The NLB takes another 2-3 minutes to pass health checks."
  echo "Use this address as GATEWAY_BASE_URL for the DG Bank app (M2)."
  echo ""
  exit 0
fi

# ---------------------------------------------------------------------------
# --deploy-mcp — DG Bank banking tools (MCP server) in the cluster
#   In-cluster Service  → the AI Gateway's MCP upstream (Test 4)
#   Internal NLB        → the DG Bank app calling the tools directly (Test 3)
# The bearer token is generated once, kept in a Kubernetes Secret and copied to
# SSM (/dgbank/mcp-token) so the ECS app can read it.
# ---------------------------------------------------------------------------
if [[ "$MODE" == "deploy-mcp" ]]; then
  use_cluster
  MCP_NS="dgbank-mcp"
  MCP_REPO="dgbank-mcp"
  ECR_HOST="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
  MCP_TAG="$(date +%Y%m%d%H%M%S)"
  MCP_IMAGE="$ECR_HOST/$MCP_REPO:$MCP_TAG"

  echo "Ensuring ECR repository $MCP_REPO exists..."
  aws ecr describe-repositories --repository-names "$MCP_REPO" --region "$REGION" > /dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$MCP_REPO" --region "$REGION" \
      --image-scanning-configuration scanOnPush=true > /dev/null

  echo "Building and pushing $MCP_IMAGE (linux/amd64)..."
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_HOST" > /dev/null
  docker build --platform linux/amd64 -t "$MCP_IMAGE" "$SCRIPT_DIR/mcp"
  docker push "$MCP_IMAGE" > /dev/null
  echo ""

  kubectl get namespace "$MCP_NS" > /dev/null 2>&1 || kubectl create namespace "$MCP_NS" > /dev/null
  if ! kubectl get secret dgbank-mcp-token -n "$MCP_NS" > /dev/null 2>&1; then
    echo "Generating MCP bearer token..."
    kubectl create secret generic dgbank-mcp-token -n "$MCP_NS" \
      --from-literal=token="$(openssl rand -hex 24)" > /dev/null
  fi
  MCP_TOKEN=$(kubectl get secret dgbank-mcp-token -n "$MCP_NS" -o jsonpath='{.data.token}' | base64 --decode)
  aws ssm put-parameter --name /dgbank/mcp-token --type SecureString --overwrite \
    --value "$MCP_TOKEN" --region "$REGION" > /dev/null
  echo "Token stored in Secret $MCP_NS/dgbank-mcp-token and SSM /dgbank/mcp-token."

  VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$(get_output VpcId)" --region "$REGION" \
    --query "Vpcs[0].CidrBlock" --output text)
  sed -e "s|__IMAGE__|$MCP_IMAGE|" -e "s|__VPC_CIDR__|$VPC_CIDR|" "$SCRIPT_DIR/mcp/k8s.yaml" | kubectl apply -f -
  kubectl rollout status deployment/dgbank-mcp -n "$MCP_NS" --timeout=180s

  # Optional public HTTPS endpoint. In the preview, the console's MCP tool discovery runs
  # from Vision One rather than from this gateway, so it can't reach in-cluster or internal
  # addresses. TLS terminates at the NLB with the ACM certificate; the bearer token is still
  # required. Pinned to the ECS stack's public subnets so it never lands in the firewall subnets.
  if [[ -n "$MCP_PUBLIC_CERT" ]]; then
    PUB_SUBNETS="$(stack_resource PublicSubnetA),$(stack_resource PublicSubnetB)"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: dgbank-mcp-public
  namespace: $MCP_NS
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-subnets: "$PUB_SUBNETS"
    service.beta.kubernetes.io/aws-load-balancer-ssl-cert: "$MCP_PUBLIC_CERT"
    service.beta.kubernetes.io/aws-load-balancer-ssl-ports: "443"
spec:
  type: LoadBalancer
  selector: { app: dgbank-mcp }
  ports:
    - { name: https, port: 443, targetPort: http }
EOF
  fi

  lb_host() {
    local host=""
    for _ in $(seq 1 40); do
      host=$(kubectl get svc "$1" -n "$MCP_NS" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
      [[ -n "$host" ]] && break
      sleep 6
    done
    echo "$host"
  }
  echo "Waiting for load balancer addresses (~2 minutes)..."
  MCP_HOST=$(lb_host dgbank-mcp-internal)
  MCP_PUBLIC_HOST=""
  [[ -n "$MCP_PUBLIC_CERT" ]] && MCP_PUBLIC_HOST=$(lb_host dgbank-mcp-public)

  echo ""
  echo "================================================="
  echo "  DG Bank MCP server deployed ($MCP_TAG)"
  echo "================================================="
  echo ""
  echo "1. Vision One console → AI Gateway → Resources → MCP → Add MCP upstream:"
  echo "     Name:       dgbank-mcp"
  echo "     Transport:  HTTP"
  if [[ -n "$MCP_PUBLIC_CERT" ]]; then
    echo "     URL:        https://<your DNS name>/mcp"
    echo "                 (CNAME your DNS name, covered by the certificate, to ${MCP_PUBLIC_HOST:-<pending NLB>})"
  else
    echo "     URL:        http://dgbank-mcp.$MCP_NS.svc.cluster.local/mcp"
    echo "                 (console discovery can't reach this address; add the six tools by hand,"
    echo "                  or rerun with --mcp-public-cert <ACM ARN> for a public HTTPS endpoint)"
  fi
  echo "     Auth:       None, plus header  Authorization = Bearer $MCP_TOKEN"
  echo "                 (click Add next to the header before Save changes)"
  echo "   Then run tool discovery and check Resources → Discovered Tools (6 tools)."
  echo ""
  echo "2. Point the DG Bank app at the tools (direct route, Test 3):"
  echo "     ./deploy-ecs.sh --github-org <org> --skip-oidc --mcp-url http://${MCP_HOST:-<pending NLB>}/mcp"
  echo "   The NLBs need 2-3 minutes before their targets are healthy."
  echo ""
  exit 0
fi

# ---------------------------------------------------------------------------
# --delete — remove the NLB first so its ENIs and security groups don't block
# the stack delete, then the gateway release, controller and stack
# ---------------------------------------------------------------------------
if [[ "$MODE" == "delete" ]]; then
  if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" > /dev/null 2>&1; then
    use_cluster
    LB_NS=$(kubectl get svc -A --field-selector "metadata.name=$LB_SERVICE_NAME" \
      -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
    if [[ -n "$LB_NS" ]]; then
      echo "Removing internal load balancer Service..."
      kubectl delete svc "$LB_SERVICE_NAME" -n "$LB_NS" --wait=true || true
    fi

    GW_RELEASE_NS=$(helm list -A -o json | jq -r --arg r "$GATEWAY_RELEASE" '.[] | select(.name==$r) | .namespace')
    if [[ -n "$GW_RELEASE_NS" ]]; then
      echo "Uninstalling Helm release $GATEWAY_RELEASE ($GW_RELEASE_NS)..."
      helm uninstall "$GATEWAY_RELEASE" -n "$GW_RELEASE_NS" --wait || true
      # Helm leaves StatefulSet volume claims behind. Delete them while the EBS
      # CSI driver is still running so it removes the EBS volumes too.
      echo "Deleting the gateway's persistent volumes..."
      kubectl delete pvc --all -n "$GW_RELEASE_NS" --wait=true || true
    fi

    if kubectl get namespace dgbank-mcp > /dev/null 2>&1; then
      echo "Removing the DG Bank MCP server and its load balancer..."
      kubectl delete namespace dgbank-mcp --wait=true || true
    fi

    echo "Uninstalling Amazon EBS CSI driver..."
    helm uninstall aws-ebs-csi-driver -n kube-system --wait 2>/dev/null || true

    echo "Uninstalling AWS Load Balancer Controller..."
    helm uninstall aws-load-balancer-controller -n kube-system --wait 2>/dev/null || true
  fi

  echo "Deleting CloudFormation stack: $STACK_NAME ..."
  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"

  echo "Deleting IAM policy $LBC_POLICY_NAME..."
  aws iam delete-policy \
    --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$LBC_POLICY_NAME" 2>/dev/null || true

  echo ""
  echo "AI Gateway cluster removed. The ECS stack is untouched."
  echo "Also remove the gateway instance under Management in the Vision One console."
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 1 — Look up the ECS stack's VPC and subnets
# ---------------------------------------------------------------------------
echo "Reading network from ECS stack: $ECS_STACK ..."
VPC_ID=$(stack_resource VPC)
SUBNET_A=$(stack_resource PublicSubnetA)
SUBNET_B=$(stack_resource PublicSubnetB)
echo "VPC         : $VPC_ID"
echo "Subnets     : $SUBNET_A, $SUBNET_B"
echo ""

# ---------------------------------------------------------------------------
# Step 2 — IAM policy for the AWS Load Balancer Controller
# The policy JSON is published with each controller release; fetch the one
# that matches the chart we're about to install.
# ---------------------------------------------------------------------------
helm repo add eks https://aws.github.io/eks-charts > /dev/null 2>&1 || true
helm repo update eks > /dev/null

LBC_CHART_ARGS=()
[[ -n "$LBC_CHART_VERSION" ]] && LBC_CHART_ARGS=(--version "$LBC_CHART_VERSION")
LBC_APP_VERSION=$(helm show chart eks/aws-load-balancer-controller ${LBC_CHART_ARGS[@]+"${LBC_CHART_ARGS[@]}"} \
  | awk '/^appVersion:/ {print $2}')

LBC_POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/$LBC_POLICY_NAME"
if aws iam get-policy --policy-arn "$LBC_POLICY_ARN" > /dev/null 2>&1; then
  echo "Load Balancer Controller IAM policy already exists."
else
  echo "Creating Load Balancer Controller IAM policy ($LBC_APP_VERSION)..."
  POLICY_FILE=$(mktemp)
  curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/$LBC_APP_VERSION/docs/install/iam_policy.json" \
    -o "$POLICY_FILE"
  aws iam create-policy \
    --policy-name "$LBC_POLICY_NAME" \
    --policy-document "file://$POLICY_FILE" > /dev/null
  rm -f "$POLICY_FILE"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 3 — Deploy CloudFormation stack (~15 minutes on first run)
# ---------------------------------------------------------------------------
echo "Deploying CloudFormation stack: $STACK_NAME (first run takes ~15 minutes)..."
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    VpcId="$VPC_ID" \
    SubnetIds="$SUBNET_A,$SUBNET_B" \
    ClusterName="$CLUSTER_NAME" \
    KubernetesVersion="$K8S_VERSION" \
    NodeInstanceType="$NODE_INSTANCE_TYPE" \
    NodeCount="$NODE_COUNT" \
    PublicAccessCidr="$PUBLIC_ACCESS_CIDR" \
    LoadBalancerControllerPolicyArn="$LBC_POLICY_ARN" || true

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
# Step 4 — kubectl access
# ---------------------------------------------------------------------------
echo "Configuring kubectl..."
use_cluster
kubectl wait --for=condition=Ready nodes --all --timeout=300s
echo ""

# ---------------------------------------------------------------------------
# Step 5 — AWS Load Balancer Controller
# Nodes only allow IMDSv2 with a hop limit of 1, so pods can't discover the
# region or VPC from instance metadata — pass both explicitly.
# ---------------------------------------------------------------------------
echo "Installing AWS Load Balancer Controller ($LBC_APP_VERSION)..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  ${LBC_CHART_ARGS[@]+"${LBC_CHART_ARGS[@]}"} \
  --namespace kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --wait

# ---------------------------------------------------------------------------
# Step 6 — Amazon EBS CSI driver + default gp3 StorageClass
# The controller can't read the region from instance metadata (hop limit 1),
# so pass it explicitly. Volume claims created before this step (e.g. a Redis
# claim stuck in Pending) pick up the new default class automatically.
# ---------------------------------------------------------------------------
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver > /dev/null 2>&1 || true
helm repo update aws-ebs-csi-driver > /dev/null

EBS_CHART_ARGS=()
[[ -n "$EBS_CSI_CHART_VERSION" ]] && EBS_CHART_ARGS=(--version "$EBS_CSI_CHART_VERSION")

EBS_VALUES=$(mktemp)
cat > "$EBS_VALUES" <<EOF
controller:
  region: $REGION
  serviceAccount:
    create: true
    name: ebs-csi-controller-sa
storageClasses:
  - name: gp3
    annotations:
      storageclass.kubernetes.io/is-default-class: "true"
    volumeBindingMode: WaitForFirstConsumer
    reclaimPolicy: Delete
    allowVolumeExpansion: true
    parameters:
      type: gp3
      encrypted: "true"
EOF

echo "Installing Amazon EBS CSI driver..."
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  ${EBS_CHART_ARGS[@]+"${EBS_CHART_ARGS[@]}"} \
  --namespace kube-system \
  -f "$EBS_VALUES" \
  --wait
rm -f "$EBS_VALUES"
kubectl get storageclass

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "================================================="
echo "  EKS cluster ready: $CLUSTER_NAME"
echo "================================================="
echo ""
kubectl get nodes -o wide
echo ""
echo "Next steps:"
echo ""
echo "1. Vision One console → AI Gateway → Management → Set up AI Gateway"
echo "   Enter a name, then copy the generated Helm command, override file and"
echo "   bootstrap token. Keep the release name '$GATEWAY_RELEASE'."
echo ""
echo "2. Run that Helm command in this terminal (kubectl already points at the cluster)."
echo "   Don't commit the override file — it contains your bootstrap token."
echo ""
echo "3. Check the pods start:  kubectl get pods -A"
echo ""
echo "4. Expose the gateway inside the VPC:"
echo "   $0 --expose"
echo ""
echo "5. Confirm the instance shows as connected under Management in the console."
echo ""
