#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# CCC Fleet Status - Colored Health Output
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fleet-config.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'
BOLD='\033[1m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ok()   { echo -e "  ${GREEN}*${NC} $*"; }
warn() { echo -e "  ${YELLOW}*${NC} $*"; }
err()  { echo -e "  ${RED}*${NC} $*"; }
dim()  { echo -e "  ${DIM}$*${NC}"; }

stack_status() {
  local name="$1"
  local status
  status=$(_aws cloudformation describe-stacks --stack-name "$name" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")
  echo "$status"
}

colorize_status() {
  local status="$1"
  case "$status" in
    *COMPLETE)       echo -e "${GREEN}${status}${NC}" ;;
    *IN_PROGRESS)    echo -e "${YELLOW}${status}${NC}" ;;
    *FAILED|*ROLLBACK*) echo -e "${RED}${status}${NC}" ;;
    NOT_FOUND)       echo -e "${DIM}not deployed${NC}" ;;
    *)               echo -e "${YELLOW}${status}${NC}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
echo ""
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  CCC Fleet Status :: ${BOLD}${FLEET_NAME}${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""

# ---------------------------------------------------------------------------
# Stack status
# ---------------------------------------------------------------------------
echo -e "${BOLD}CloudFormation Stacks${NC}"
echo ""

STACKS=(network storage workers proxy)
ALL_HEALTHY=true

for stack in "${STACKS[@]}"; do
  full_name="$(_stack_name "$stack")"
  status=$(stack_status "$full_name")
  colored=$(colorize_status "$status")
  printf "  %-30s %s\n" "$full_name" "$colored"
  if [[ "$status" != *"COMPLETE"* || "$status" == *"ROLLBACK"* ]]; then
    ALL_HEALTHY=false
  fi
done

echo ""

# ---------------------------------------------------------------------------
# Proxy endpoint
# ---------------------------------------------------------------------------
echo -e "${BOLD}Endpoints${NC}"
echo ""

PROXY_IP=$(_aws cloudformation describe-stacks \
  --stack-name "$(_stack_name proxy)" \
  --query "Stacks[0].Outputs[?OutputKey=='ProxyPublicIp'].OutputValue" \
  --output text 2>/dev/null || echo "")

if [[ -n "$PROXY_IP" && "$PROXY_IP" != "None" ]]; then
  ok "Dashboard:  http://$PROXY_IP"
  ok "API:        http://$PROXY_IP/api"
else
  warn "Proxy IP not available (stack not deployed?)"
fi

echo ""

# ---------------------------------------------------------------------------
# Worker instances
# ---------------------------------------------------------------------------
echo -e "${BOLD}Worker Instances${NC}"
echo ""

ASG_NAME="${FLEET_NAME}-workers"
INSTANCE_IDS=$(_aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]' \
  --output text 2>/dev/null || echo "")

if [[ -z "$INSTANCE_IDS" || "$INSTANCE_IDS" == "None" ]]; then
  warn "No worker instances found"
else
  HEALTHY_COUNT=0
  TOTAL_COUNT=0
  while IFS=$'\t' read -r id lifecycle health; do
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    IP=$(_aws ec2 describe-instances --instance-ids "$id" \
      --query 'Reservations[0].Instances[0].PrivateIpAddress' \
      --output text 2>/dev/null || echo "N/A")

    if [[ "$lifecycle" == "InService" && "$health" == "Healthy" ]]; then
      ok "$id  $IP  ${GREEN}$lifecycle${NC}  ${GREEN}$health${NC}"
      HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
    else
      err "$id  $IP  ${YELLOW}$lifecycle${NC}  ${RED}$health${NC}"
    fi
  done <<< "$INSTANCE_IDS"

  echo ""
  if [[ $HEALTHY_COUNT -eq $TOTAL_COUNT ]]; then
    ok "${GREEN}${BOLD}$HEALTHY_COUNT/$TOTAL_COUNT workers healthy${NC}"
  else
    warn "${YELLOW}${BOLD}$HEALTHY_COUNT/$TOTAL_COUNT workers healthy${NC}"
  fi
fi

echo ""

# ---------------------------------------------------------------------------
# Worker API health (if proxy is up)
# ---------------------------------------------------------------------------
if [[ -n "$PROXY_IP" && "$PROXY_IP" != "None" ]]; then
  echo -e "${BOLD}API Health Check${NC}"
  echo ""

  HEALTH_RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 "http://$PROXY_IP/api/health" 2>/dev/null || echo "")
  if [[ -n "$HEALTH_RESPONSE" ]]; then
    TASKS_COMPLETED=$(echo "$HEALTH_RESPONSE" | jq -r '.tasks_completed // 0' 2>/dev/null || echo "?")
    TASKS_RUNNING=$(echo "$HEALTH_RESPONSE" | jq -r '.tasks_running // 0' 2>/dev/null || echo "?")
    UPTIME=$(echo "$HEALTH_RESPONSE" | jq -r '.uptime // "N/A"' 2>/dev/null || echo "?")
    ok "Tasks completed: $TASKS_COMPLETED"
    ok "Tasks running:   $TASKS_RUNNING"
    ok "Uptime:          $UPTIME"
  else
    warn "API not responding (workers may still be starting)"
  fi

  echo ""
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if $ALL_HEALTHY; then
  echo -e "  ${GREEN}${BOLD}Fleet is operational.${NC}"
else
  echo -e "  ${YELLOW}${BOLD}Fleet has issues -- check stack status above.${NC}"
fi
echo ""
