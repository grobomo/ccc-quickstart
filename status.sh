#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# CCC Fleet Status - Colored health dashboard
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
DIM='\033[2m'

echo ""
echo -e "${CYAN}${BOLD}  CCC Fleet Status :: $FLEET_NAME${NC}"
echo -e "${CYAN}  $(printf '=%.0s' {1..50})${NC}"
echo ""

# ---------------------------------------------------------------------------
# Stack status
# ---------------------------------------------------------------------------
echo -e "${BOLD}  CloudFormation Stacks${NC}"
echo -e "  ${DIM}$(printf -- '-%.0s' {1..50})${NC}"

for component in network storage workers proxy; do
  stack="$(_stack_name $component)"
  status=$(_aws cloudformation describe-stacks --stack-name "$stack" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")

  case "$status" in
    *COMPLETE*)
      color=$GREEN
      icon="[+]"
      ;;
    *PROGRESS*)
      color=$YELLOW
      icon="[~]"
      ;;
    *FAILED*|*ROLLBACK*)
      color=$RED
      icon="[X]"
      ;;
    *)
      color=$DIM
      icon="[-]"
      ;;
  esac

  printf "  ${color}${icon}${NC} %-12s %s\n" "$component" "$status"
done

echo ""

# ---------------------------------------------------------------------------
# Worker instances
# ---------------------------------------------------------------------------
echo -e "${BOLD}  Worker Instances${NC}"
echo -e "  ${DIM}$(printf -- '-%.0s' {1..50})${NC}"

ASG_NAME="${FLEET_NAME}-workers"
INSTANCE_IDS=$(_aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[*].[InstanceId,HealthStatus,LifecycleState]' \
  --output text 2>/dev/null || echo "")

if [[ -z "$INSTANCE_IDS" ]]; then
  echo -e "  ${DIM}[-] No worker instances found${NC}"
else
  HEALTHY=0
  TOTAL=0
  while IFS=$'\t' read -r id health lifecycle; do
    TOTAL=$((TOTAL + 1))
    case "$health" in
      Healthy)
        color=$GREEN
        icon="[+]"
        HEALTHY=$((HEALTHY + 1))
        ;;
      *)
        color=$RED
        icon="[X]"
        ;;
    esac

    # Get private IP
    IP=$(_aws ec2 describe-instances --instance-ids "$id" \
      --query 'Reservations[0].Instances[0].PrivateIpAddress' \
      --output text 2>/dev/null || echo "N/A")

    printf "  ${color}${icon}${NC} %-22s %-10s %-16s %s\n" "$id" "$health" "$lifecycle" "$IP"
  done <<< "$INSTANCE_IDS"

  echo ""
  if [[ $HEALTHY -eq $TOTAL ]]; then
    echo -e "  ${GREEN}${BOLD}All $TOTAL workers healthy${NC}"
  else
    echo -e "  ${YELLOW}${BOLD}$HEALTHY/$TOTAL workers healthy${NC}"
  fi
fi

echo ""

# ---------------------------------------------------------------------------
# Proxy status
# ---------------------------------------------------------------------------
echo -e "${BOLD}  Proxy${NC}"
echo -e "  ${DIM}$(printf -- '-%.0s' {1..50})${NC}"

PROXY_IP=$(_aws cloudformation describe-stacks \
  --stack-name "$(_stack_name proxy)" \
  --query "Stacks[0].Outputs[?OutputKey=='ProxyPublicIp'].OutputValue" \
  --output text 2>/dev/null || echo "")

if [[ -n "$PROXY_IP" && "$PROXY_IP" != "None" ]]; then
  echo -e "  ${GREEN}[+]${NC} IP: $PROXY_IP"

  # Check HTTP
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://$PROXY_IP/api/health" 2>/dev/null || echo "000")
  if [[ "$HTTP_STATUS" == "200" ]]; then
    echo -e "  ${GREEN}[+]${NC} API: healthy (HTTP $HTTP_STATUS)"

    # Get fleet health
    HEALTH=$(curl -s --connect-timeout 5 "http://$PROXY_IP/api/health" 2>/dev/null || echo "{}")
    TASKS=$(echo "$HEALTH" | jq -r '.tasks_completed // 0' 2>/dev/null || echo "0")
    QUEUED=$(echo "$HEALTH" | jq -r '.tasks_queued // 0' 2>/dev/null || echo "0")
    echo -e "  ${BLUE}[i]${NC} Tasks completed: $TASKS"
    echo -e "  ${BLUE}[i]${NC} Tasks queued: $QUEUED"
  else
    echo -e "  ${RED}[X]${NC} API: unreachable (HTTP $HTTP_STATUS)"
  fi

  echo ""
  echo -e "  ${BOLD}Dashboard:${NC} http://$PROXY_IP"
  echo -e "  ${BOLD}API:${NC}       http://$PROXY_IP/api"
else
  echo -e "  ${DIM}[-] Proxy not deployed${NC}"
fi

echo ""
