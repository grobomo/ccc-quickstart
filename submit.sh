#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# CCC Fleet Submit - Send tasks to the fleet
# =============================================================================
# Usage: ./submit.sh "Fix the login bug in auth.py"
#        ./submit.sh --file tasks.txt
#        ./submit.sh --repo --prompt "Refactor the auth module"
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/fleet-config.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

get_api_url() {
  local proxy_ip
  proxy_ip=$(_aws cloudformation describe-stacks \
    --stack-name "$(_stack_name proxy)" \
    --query "Stacks[0].Outputs[?OutputKey=='ProxyPublicIp'].OutputValue" \
    --output text 2>/dev/null || echo "")
  if [[ -z "$proxy_ip" || "$proxy_ip" == "None" ]]; then
    echo -e "${RED}[FAIL]${NC} Proxy not deployed. Run ./deploy.sh first." >&2
    exit 1
  fi
  echo "http://$proxy_ip"
}

submit_task() {
  local prompt="$1"
  local use_repo="${2:-false}"
  local api_url
  api_url=$(get_api_url)
  local payload
  payload=$(jq -n --arg prompt "$prompt" --argjson repo "$use_repo" '{prompt: $prompt, repo: $repo}')
  echo -e "${BLUE}[>>]${NC} Submitting: ${BOLD}${prompt:0:80}${NC}..."
  local response
  response=$(curl -s -X POST "$api_url/api/submit" -H "Content-Type: application/json" -d "$payload" 2>/dev/null)
  local task_id
  task_id=$(echo "$response" | jq -r '.task_id // empty' 2>/dev/null)
  if [[ -n "$task_id" ]]; then
    echo -e "${GREEN}[OK]${NC} Task submitted: $task_id"
    echo -e "${BLUE}[i]${NC}  Check status: ./submit.sh --status $task_id"
  else
    echo -e "${RED}[FAIL]${NC} Submit failed: $response"
    return 1
  fi
}

check_status() {
  local task_id="$1"
  local api_url
  api_url=$(get_api_url)
  local response
  response=$(curl -s "$api_url/api/status/$task_id" 2>/dev/null)
  local status
  status=$(echo "$response" | jq -r '.status // "unknown"' 2>/dev/null)
  case "$status" in
    completed) echo -e "${GREEN}[+]${NC} Task $task_id: ${GREEN}completed${NC}"; echo "$response" | jq -r '.stdout // empty' 2>/dev/null ;;
    running)   echo -e "${YELLOW}[~]${NC} Task $task_id: ${YELLOW}running${NC}" ;;
    failed)    echo -e "${RED}[X]${NC} Task $task_id: ${RED}failed${NC}"; echo "$response" | jq -r '.stderr // empty' 2>/dev/null ;;
    *)         echo -e "${RED}[?]${NC} Task $task_id: $status"; echo "$response" | jq . 2>/dev/null || echo "$response" ;;
  esac
}

list_tasks() {
  local api_url
  api_url=$(get_api_url)
  local response
  response=$(curl -s "$api_url/api/status" 2>/dev/null)
  echo -e "${BOLD}  Tasks${NC}"
  echo "$response" | jq -r '.tasks[] | "\(.status)\t\(.id)\t\(.prompt // "N/A" | .[0:60])"' 2>/dev/null | \
    while IFS=$'\t' read -r status id prompt; do
      case "$status" in
        completed) color=$GREEN ;; running) color=$YELLOW ;; failed) color=$RED ;; *) color=$NC ;;
      esac
      printf "  ${color}%-10s${NC} %-40s %s\n" "$status" "$id" "$prompt"
    done
}

USE_REPO=false
MODE="submit"
PROMPT=""
TASK_ID=""
FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     USE_REPO=true; shift ;;
    --file)     FILE="$2"; MODE="file"; shift 2 ;;
    --status)   TASK_ID="$2"; MODE="status"; shift 2 ;;
    --list)     MODE="list"; shift ;;
    -h|--help)  echo "Usage: $0 [--repo] [--file FILE] [--status ID] [--list] \"prompt\""; exit 0 ;;
    *)          PROMPT="$1"; shift ;;
  esac
done

case "$MODE" in
  submit)
    [[ -z "$PROMPT" ]] && { echo "Error: No prompt. Usage: $0 \"your prompt\""; exit 1; }
    submit_task "$PROMPT" "$USE_REPO"
    ;;
  file)
    [[ ! -f "$FILE" ]] && { echo "Error: File not found: $FILE"; exit 1; }
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      submit_task "$line" "$USE_REPO"
    done < "$FILE"
    ;;
  status) check_status "$TASK_ID" ;;
  list)   list_tasks ;;
esac
