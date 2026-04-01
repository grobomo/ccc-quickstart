#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# CCC Fleet Submit - Send Tasks to Fleet
# =============================================================================
# Usage:
#   ./submit.sh "Fix the login bug in auth.py"
#   ./submit.sh --repo "Fix tests"
#   ./submit.sh --file tasks.txt
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

usage() {
  echo "Usage: $0 [OPTIONS] <prompt>"
  echo ""
  echo "Options:"
  echo "  --repo          Run task in the cloned repo context"
  echo "  --file FILE     Submit each line of FILE as a separate task"
  echo "  --status ID     Check status of a specific task"
  echo "  --list          List all tasks"
  echo "  --url URL       Override API URL (default: auto-detect from stack)"
  echo ""
  echo "Examples:"
  echo "  $0 \"Fix the login bug in auth.py\""
  echo "  $0 --repo \"Add unit tests for utils.py\""
  echo "  $0 --file batch-tasks.txt"
  echo "  $0 --status task-1234567890-abc123"
  echo "  $0 --list"
  exit 1
}

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
USE_REPO=false
TASK_FILE=""
CHECK_STATUS=""
LIST_TASKS=false
API_URL_OVERRIDE=""
PROMPT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      USE_REPO=true; shift ;;
    --file)      TASK_FILE="$2"; shift 2 ;;
    --status)    CHECK_STATUS="$2"; shift 2 ;;
    --list)      LIST_TASKS=true; shift ;;
    --url)       API_URL_OVERRIDE="$2"; shift 2 ;;
    --help|-h)   usage ;;
    *)           PROMPT="$1"; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Get API URL
# ---------------------------------------------------------------------------
if [[ -n "$API_URL_OVERRIDE" ]]; then
  API_URL="$API_URL_OVERRIDE"
else
  PROXY_IP=$(_aws cloudformation describe-stacks \
    --stack-name "$(_stack_name proxy)" \
    --query "Stacks[0].Outputs[?OutputKey=='ProxyPublicIp'].OutputValue" \
    --output text 2>/dev/null || echo "")

  if [[ -z "$PROXY_IP" || "$PROXY_IP" == "None" ]]; then
    echo -e "${RED}[FAIL]${NC} Cannot find proxy IP. Is the fleet deployed?"
    echo "       Run ./deploy.sh first, or use --url to specify the API endpoint."
    exit 1
  fi
  API_URL="http://$PROXY_IP/api"
fi

# ---------------------------------------------------------------------------
# List tasks
# ---------------------------------------------------------------------------
if $LIST_TASKS; then
  echo -e "${CYAN}Tasks on ${BOLD}$FLEET_NAME${NC}"
  echo ""
  RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 "$API_URL/status" 2>/dev/null || echo "")
  if [[ -z "$RESPONSE" ]]; then
    echo -e "${RED}API not responding${NC}"
    exit 1
  fi
  echo "$RESPONSE" | jq -r '.tasks[] | "\(.id)\t\(.status)\t\(.prompt // "N/A" | .[0:60])"' 2>/dev/null | \
    while IFS=$'\t' read -r id status prompt; do
      case "$status" in
        completed) COLOR="$GREEN" ;;
        failed)    COLOR="$RED" ;;
        running)   COLOR="$YELLOW" ;;
        *)         COLOR="$NC" ;;
      esac
      printf "  %-40s ${COLOR}%-10s${NC} %s\n" "$id" "$status" "$prompt"
    done
  exit 0
fi

# ---------------------------------------------------------------------------
# Check task status
# ---------------------------------------------------------------------------
if [[ -n "$CHECK_STATUS" ]]; then
  RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 "$API_URL/status/$CHECK_STATUS" 2>/dev/null || echo "")
  if [[ -z "$RESPONSE" ]]; then
    echo -e "${RED}API not responding${NC}"
    exit 1
  fi
  echo "$RESPONSE" | jq .
  exit 0
fi

# ---------------------------------------------------------------------------
# Submit from file
# ---------------------------------------------------------------------------
if [[ -n "$TASK_FILE" ]]; then
  if [[ ! -f "$TASK_FILE" ]]; then
    echo -e "${RED}File not found: $TASK_FILE${NC}"
    exit 1
  fi

  COUNT=0
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    PAYLOAD=$(jq -n --arg p "$line" --argjson r "$USE_REPO" '{prompt: $p, repo: $r}')
    RESPONSE=$(curl -s -X POST "$API_URL/submit" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" 2>/dev/null || echo '{"error":"API unreachable"}')
    TASK_ID=$(echo "$RESPONSE" | jq -r '.task_id // "error"')
    echo -e "  ${GREEN}[OK]${NC} $TASK_ID  $line"
    COUNT=$((COUNT + 1))
  done < "$TASK_FILE"

  echo ""
  echo -e "${GREEN}Submitted $COUNT tasks${NC}"
  exit 0
fi

# ---------------------------------------------------------------------------
# Submit single task
# ---------------------------------------------------------------------------
if [[ -z "$PROMPT" ]]; then
  usage
fi

PAYLOAD=$(jq -n --arg p "$PROMPT" --argjson r "$USE_REPO" '{prompt: $p, repo: $r}')

echo -e "${CYAN}Submitting to ${BOLD}$FLEET_NAME${NC}..."
echo -e "  Prompt: ${BOLD}$PROMPT${NC}"
echo ""

RESPONSE=$(curl -s -X POST "$API_URL/submit" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>/dev/null || echo '{"error":"API unreachable"}')

ERROR=$(echo "$RESPONSE" | jq -r '.error // empty' 2>/dev/null)
if [[ -n "$ERROR" ]]; then
  echo -e "${RED}[FAIL]${NC} $ERROR"
  exit 1
fi

TASK_ID=$(echo "$RESPONSE" | jq -r '.task_id')
echo -e "${GREEN}[OK]${NC} Task submitted: ${BOLD}$TASK_ID${NC}"
echo ""
echo "  Check status:  ./submit.sh --status $TASK_ID"
echo "  List all:      ./submit.sh --list"
