#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# CCC Fleet Teardown - Clean Removal
# =============================================================================
# Usage: ./teardown.sh [--force] [--keep-bucket]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fleet-config.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

FORCE=false
KEEP_BUCKET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)       FORCE=true; shift ;;
    --keep-bucket) KEEP_BUCKET=true; shift ;;
    *)             shift ;;
  esac
done

log()  { echo -e "  ${CYAN}>>>${NC} $*"; }
ok()   { echo -e "  ${GREEN}[OK]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[!!]${NC} $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; }

echo ""
echo -e "${RED}${BOLD}================================================================${NC}"
echo -e "${RED}${BOLD}  CCC Fleet Teardown :: $FLEET_NAME${NC}"
echo -e "${RED}${BOLD}================================================================${NC}"
echo ""
echo "  This will delete:"
echo "    - CloudFormation stacks: network, storage, workers, proxy"
echo "    - Secrets Manager entries: $FLEET_NAME/*"
echo "    - SSM parameters: /$FLEET_NAME/*"
if ! $KEEP_BUCKET; then
  echo "    - S3 bucket: $S3_BUCKET (use --keep-bucket to preserve)"
fi
echo ""

if ! $FORCE; then
  read -rp "  Type the fleet name to confirm [$FLEET_NAME]: " CONFIRM
  if [[ "$CONFIRM" != "$FLEET_NAME" ]]; then
    echo ""
    echo "  Aborted."
    exit 1
  fi
fi

echo ""

# ---------------------------------------------------------------------------
# Delete stacks in reverse order
# ---------------------------------------------------------------------------
delete_stack() {
  local name="$1"
  local status
  status=$(_aws cloudformation describe-stacks --stack-name "$name" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

  if [[ "$status" == "DOES_NOT_EXIST" ]]; then
    ok "$name (already gone)"
    return 0
  fi

  log "Deleting stack: $name ($status)"
  _aws cloudformation delete-stack --stack-name "$name" --no-cli-pager 2>/dev/null || {
    fail "Failed to initiate delete for $name"
    return 1
  }

  log "Waiting for $name deletion..."
  _aws cloudformation wait stack-delete-complete --stack-name "$name" --no-cli-pager 2>/dev/null || {
    fail "$name deletion failed or timed out"
    return 1
  }

  ok "$name deleted"
}

# Reverse order: proxy -> workers -> storage -> network
STACKS=(proxy workers storage network)

for stack in "${STACKS[@]}"; do
  delete_stack "$(_stack_name "$stack")"
done

# ---------------------------------------------------------------------------
# Clean up S3 bucket (must empty before CFN can delete)
# ---------------------------------------------------------------------------
if ! $KEEP_BUCKET; then
  log "Emptying S3 bucket: $S3_BUCKET"
  _aws s3 rm "s3://$S3_BUCKET" --recursive --no-cli-pager 2>/dev/null || true
  log "Deleting S3 bucket: $S3_BUCKET"
  _aws s3 rb "s3://$S3_BUCKET" --no-cli-pager 2>/dev/null && ok "Bucket deleted" || warn "Bucket may already be gone"
fi

# ---------------------------------------------------------------------------
# Clean up secrets
# ---------------------------------------------------------------------------
log "Removing Secrets Manager entries..."
for secret in claude-api-key github-token; do
  _aws secretsmanager delete-secret \
    --secret-id "$FLEET_NAME/$secret" \
    --force-delete-without-recovery \
    --no-cli-pager 2>/dev/null && ok "Secret $FLEET_NAME/$secret deleted" || true
done

# ---------------------------------------------------------------------------
# Clean up SSM parameters
# ---------------------------------------------------------------------------
log "Removing SSM parameters..."
_aws ssm delete-parameter --name "/$FLEET_NAME/bucket" --no-cli-pager 2>/dev/null && ok "SSM /$FLEET_NAME/bucket deleted" || true

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "  ${GREEN}${BOLD}Fleet $FLEET_NAME has been torn down.${NC}"
echo ""
