#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# CCC Fleet Teardown - Clean removal of all resources
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fleet-config.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

echo ""
echo -e "${CYAN}${BOLD}  CCC Fleet Teardown :: $FLEET_NAME${NC}"
echo -e "${CYAN}  $(printf '=%.0s' {1..50})${NC}"
echo ""

# Confirm
echo -e "${YELLOW}[!!]${NC} This will delete ALL resources for fleet: ${BOLD}$FLEET_NAME${NC}"
echo -e "     Region: $AWS_REGION"
echo ""
read -rp "Type the fleet name to confirm: " CONFIRM
if [[ "$CONFIRM" != "$FLEET_NAME" ]]; then
  echo -e "${RED}[FAIL]${NC} Confirmation failed. Aborting."
  exit 1
fi

echo ""

delete_stack() {
  local stack="$1"
  local status
  status=$(_aws cloudformation describe-stacks --stack-name "$stack" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$status" == "NOT_FOUND" ]]; then
    echo -e "  ${GREEN}[+]${NC} $stack: already gone"
    return 0
  fi

  echo -e "  ${YELLOW}[~]${NC} Deleting $stack..."
  _aws cloudformation delete-stack --stack-name "$stack" --no-cli-pager 2>/dev/null
  _aws cloudformation wait stack-delete-complete --stack-name "$stack" --no-cli-pager 2>/dev/null || {
    echo -e "  ${RED}[X]${NC} $stack: delete failed (may need manual cleanup)"
    return 1
  }
  echo -e "  ${GREEN}[+]${NC} $stack: deleted"
}

# Delete in reverse order (proxy -> workers -> storage -> network)
echo -e "${BOLD}Deleting stacks...${NC}"
delete_stack "$(_stack_name proxy)"
delete_stack "$(_stack_name workers)"

# Delete secrets
echo -e "${BOLD}Deleting secrets...${NC}"
_aws secretsmanager delete-secret --secret-id "$FLEET_NAME/claude-api-key" --force-delete-without-recovery --no-cli-pager 2>/dev/null && \
  echo -e "  ${GREEN}[+]${NC} claude-api-key deleted" || \
  echo -e "  ${GREEN}[+]${NC} claude-api-key: already gone"
_aws secretsmanager delete-secret --secret-id "$FLEET_NAME/github-token" --force-delete-without-recovery --no-cli-pager 2>/dev/null && \
  echo -e "  ${GREEN}[+]${NC} github-token deleted" || \
  echo -e "  ${GREEN}[+]${NC} github-token: already gone"

# Delete SSM parameter
_aws ssm delete-parameter --name "/$FLEET_NAME/bucket" --no-cli-pager 2>/dev/null && \
  echo -e "  ${GREEN}[+]${NC} SSM parameter deleted" || true

# Storage stack (S3 bucket has DeletionPolicy: Retain)
delete_stack "$(_stack_name storage)"
echo -e "  ${YELLOW}[!!]${NC} S3 bucket ${BOLD}$S3_BUCKET${NC} retained (DeletionPolicy: Retain)"
echo -e "      To delete: aws s3 rb s3://$S3_BUCKET --force $(_region_arg)"

# Network last
delete_stack "$(_stack_name network)"

echo ""
echo -e "${GREEN}${BOLD}  Fleet $FLEET_NAME torn down.${NC}"
echo ""
