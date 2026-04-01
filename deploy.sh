#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# CCC Fleet Deploy - One-Click Deployment
# =============================================================================
# Usage: ./deploy.sh [--dry-run]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fleet-config.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo -e "${BLUE}[>>]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!!]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

banner() {
  echo ""
  echo -e "${CYAN}================================================================${NC}"
  echo -e "${CYAN}  CCC Fleet Quickstart :: ${BOLD}$1${NC}"
  echo -e "${CYAN}================================================================${NC}"
  echo ""
}

wait_stack() {
  local stack="$1"
  local timeout="${2:-600}"
  log "Waiting for stack $stack (timeout: ${timeout}s)..."
  if $DRY_RUN; then
    ok "DRY RUN: would wait for $stack"
    return 0
  fi
  _aws cloudformation wait stack-create-complete \
    --stack-name "$stack" \
    --no-cli-pager 2>/dev/null || {
      local status=$(_aws cloudformation describe-stacks --stack-name "$stack" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "UNKNOWN")
      fail "Stack $stack failed with status: $status"
    }
  ok "Stack $stack ready"
}

deploy_stack() {
  local stack_name="$1"
  local template="$2"
  shift 2
  local params=("$@")

  log "Deploying stack: $stack_name"
  if $DRY_RUN; then
    ok "DRY RUN: would deploy $stack_name with template $template"
    return 0
  fi

  # Check if stack exists
  local stack_status
  stack_status=$(_aws cloudformation describe-stacks --stack-name "$stack_name" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  local cmd="create-stack"
  if [[ "$stack_status" != "DOES_NOT_EXIST" ]]; then
    if [[ "$stack_status" == *"COMPLETE"* || "$stack_status" == *"FAILED"* ]]; then
      cmd="update-stack"
      warn "Stack $stack_name exists ($stack_status), updating..."
    else
      fail "Stack $stack_name in unexpected state: $stack_status"
    fi
  fi

  _aws cloudformation $cmd \
    --stack-name "$stack_name" \
    --template-body "file://$template" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters "${params[@]}" \
    --tags "Key=Fleet,Value=$FLEET_NAME" \
    --no-cli-pager 2>/dev/null || {
      # "No updates" is OK for update-stack
      if [[ "$cmd" == "update-stack" ]]; then
        warn "No updates needed for $stack_name"
        return 0
      fi
      fail "Failed to deploy $stack_name"
    }

  if [[ "$cmd" == "create-stack" ]]; then
    wait_stack "$stack_name"
  else
    _aws cloudformation wait stack-update-complete --stack-name "$stack_name" --no-cli-pager 2>/dev/null || true
    ok "Stack $stack_name updated"
  fi
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
banner "Preflight Checks"

# AWS CLI
command -v aws >/dev/null 2>&1 || fail "AWS CLI not found. Install: https://aws.amazon.com/cli/"
ok "AWS CLI found"

# AWS credentials
_aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1 || fail "AWS credentials not configured"
AWS_ACCOUNT=$(_aws sts get-caller-identity --query Account --output text)
ok "AWS Account: $AWS_ACCOUNT"

# Docker (optional - only needed for local build)
if command -v docker >/dev/null 2>&1; then
  ok "Docker found (local builds available)"
else
  warn "Docker not found (workers will build from S3)"
fi

# Required secrets
[[ -n "$CLAUDE_API_KEY" ]] || fail "CLAUDE_API_KEY not set in fleet-config.sh or environment"
ok "Claude API key configured"

if [[ -n "$GITHUB_TOKEN" ]]; then
  ok "GitHub token configured"
else
  warn "GITHUB_TOKEN not set (workers won't clone repos)"
fi

# SSH key
if [[ -n "$SSH_KEY_NAME" ]]; then
  _aws ec2 describe-key-pairs --key-names "$SSH_KEY_NAME" --no-cli-pager >/dev/null 2>&1 \
    || fail "SSH key pair '$SSH_KEY_NAME' not found in AWS"
  ok "SSH key pair: $SSH_KEY_NAME"
else
  warn "SSH_KEY_NAME not set (no SSH access to instances)"
fi

echo ""
log "Fleet: ${BOLD}$FLEET_NAME${NC}"
log "Region: $AWS_REGION"
log "Workers: $WORKER_COUNT x $WORKER_INSTANCE_TYPE (spot: $USE_SPOT)"
log "Proxy: $PROXY_INSTANCE_TYPE"
log "S3 Bucket: $S3_BUCKET"
echo ""

# ---------------------------------------------------------------------------
# Deploy stacks
# ---------------------------------------------------------------------------
banner "Deploying Network"
deploy_stack "$(_stack_name network)" \
  "$SCRIPT_DIR/cloudformation/network.yaml" \
  "ParameterKey=FleetName,ParameterValue=$FLEET_NAME" \
  "ParameterKey=VpcCidr,ParameterValue=$VPC_CIDR" \
  "ParameterKey=AdminIp,ParameterValue=$ADMIN_IP"

banner "Deploying Storage"
deploy_stack "$(_stack_name storage)" \
  "$SCRIPT_DIR/cloudformation/storage.yaml" \
  "ParameterKey=FleetName,ParameterValue=$FLEET_NAME" \
  "ParameterKey=BucketName,ParameterValue=$S3_BUCKET"

# ---------------------------------------------------------------------------
# Store secrets
# ---------------------------------------------------------------------------
banner "Storing Secrets"
if ! $DRY_RUN; then
  # Claude API Key
  _aws secretsmanager create-secret \
    --name "$FLEET_NAME/claude-api-key" \
    --secret-string "$CLAUDE_API_KEY" \
    --tags "Key=Fleet,Value=$FLEET_NAME" \
    --no-cli-pager 2>/dev/null || \
  _aws secretsmanager update-secret \
    --secret-id "$FLEET_NAME/claude-api-key" \
    --secret-string "$CLAUDE_API_KEY" \
    --no-cli-pager 2>/dev/null
  ok "Claude API key stored"

  # GitHub Token
  if [[ -n "$GITHUB_TOKEN" ]]; then
    _aws secretsmanager create-secret \
      --name "$FLEET_NAME/github-token" \
      --secret-string "$GITHUB_TOKEN" \
      --tags "Key=Fleet,Value=$FLEET_NAME" \
      --no-cli-pager 2>/dev/null || \
    _aws secretsmanager update-secret \
      --secret-id "$FLEET_NAME/github-token" \
      --secret-string "$GITHUB_TOKEN" \
      --no-cli-pager 2>/dev/null
    ok "GitHub token stored"
  fi

  # Store bucket name in SSM for worker discovery
  _aws ssm put-parameter \
    --name "/$FLEET_NAME/bucket" \
    --value "$S3_BUCKET" \
    --type String \
    --overwrite \
    --no-cli-pager 2>/dev/null
  ok "SSM parameters stored"
else
  ok "DRY RUN: would store secrets"
fi

# ---------------------------------------------------------------------------
# Upload Docker assets to S3
# ---------------------------------------------------------------------------
banner "Uploading Worker Assets"
if ! $DRY_RUN; then
  _aws s3 cp "$SCRIPT_DIR/Dockerfile" "s3://$S3_BUCKET/docker/Dockerfile" --no-cli-pager 2>/dev/null
  _aws s3 cp "$SCRIPT_DIR/entrypoint.sh" "s3://$S3_BUCKET/docker/entrypoint.sh" --no-cli-pager 2>/dev/null
  ok "Docker assets uploaded to s3://$S3_BUCKET/docker/"
else
  ok "DRY RUN: would upload Docker assets"
fi

# ---------------------------------------------------------------------------
# Deploy workers
# ---------------------------------------------------------------------------
banner "Deploying Workers"
WORKER_PARAMS=(
  "ParameterKey=FleetName,ParameterValue=$FLEET_NAME"
  "ParameterKey=WorkerCount,ParameterValue=$WORKER_COUNT"
  "ParameterKey=InstanceType,ParameterValue=$WORKER_INSTANCE_TYPE"
  "ParameterKey=UseSpot,ParameterValue=$USE_SPOT"
  "ParameterKey=KeyName,ParameterValue=${SSH_KEY_NAME:-}"
)
[[ -n "$SPOT_MAX_PRICE" ]] && WORKER_PARAMS+=("ParameterKey=SpotMaxPrice,ParameterValue=$SPOT_MAX_PRICE")

deploy_stack "$(_stack_name workers)" \
  "$SCRIPT_DIR/cloudformation/workers.yaml" \
  "${WORKER_PARAMS[@]}"

# ---------------------------------------------------------------------------
# Deploy proxy
# ---------------------------------------------------------------------------
banner "Deploying Proxy"
deploy_stack "$(_stack_name proxy)" \
  "$SCRIPT_DIR/cloudformation/proxy.yaml" \
  "ParameterKey=FleetName,ParameterValue=$FLEET_NAME" \
  "ParameterKey=InstanceType,ParameterValue=$PROXY_INSTANCE_TYPE" \
  "ParameterKey=KeyName,ParameterValue=${SSH_KEY_NAME:-}"

# ---------------------------------------------------------------------------
# Get outputs
# ---------------------------------------------------------------------------
banner "Fleet Ready!"

if ! $DRY_RUN; then
  PROXY_IP=$(_aws cloudformation describe-stacks \
    --stack-name "$(_stack_name proxy)" \
    --query "Stacks[0].Outputs[?OutputKey=='ProxyPublicIp'].OutputValue" \
    --output text 2>/dev/null || echo "pending")

  DASHBOARD_URL="http://$PROXY_IP"
  API_URL="http://$PROXY_IP/api"
else
  PROXY_IP="DRY-RUN"
  DASHBOARD_URL="http://DRY-RUN"
  API_URL="http://DRY-RUN/api"
fi

echo -e "${GREEN}${BOLD}"
echo "  ============================================"
echo "  Fleet:      $FLEET_NAME"
echo "  Dashboard:  $DASHBOARD_URL"
echo "  API:        $API_URL"
echo "  Workers:    $WORKER_COUNT x $WORKER_INSTANCE_TYPE"
echo "  Region:     $AWS_REGION"
echo "  ============================================"
echo -e "${NC}"
echo ""
echo "  Submit a task:  ./submit.sh \"Fix the login bug in auth.py\""
echo "  Fleet status:   ./status.sh"
echo "  Tear down:      ./teardown.sh"
echo ""
