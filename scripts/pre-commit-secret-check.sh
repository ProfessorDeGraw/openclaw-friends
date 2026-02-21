#!/bin/bash
# pre-commit-secret-check.sh — Block commits containing secrets
#
# Scans staged files for token patterns before allowing a commit.
# Install as .git/hooks/pre-commit or run standalone to audit.
#
# Usage:
#   .git/hooks/pre-commit          (automatic — called by git)
#   ./scripts/pre-commit-secret-check.sh          # audit staged files
#   ./scripts/pre-commit-secret-check.sh --all    # audit entire repo
#   ./scripts/pre-commit-secret-check.sh --diff HEAD~3  # audit recent commits
#
# Exit: 0 = clean, 1 = secrets found (commit blocked)

set -euo pipefail

RED='\033[0;31m'; YEL='\033[0;33m'; GRN='\033[0;32m'
BLD='\033[1m'; DIM='\033[2m'; RST='\033[0m'

# ─── Secret Patterns ─────────────────────────────────────────────
#
# Each line: <label>|<regex>
# Patterns are extended grep (-E). Case-sensitive unless noted.

PATTERNS=(
  # GitHub tokens
  "GitHub Copilot Token|ghu_[A-Za-z0-9]{36,}"
  "GitHub PAT (classic)|ghp_[A-Za-z0-9]{36,}"
  "GitHub OAuth Token|gho_[A-Za-z0-9]{36,}"
  "GitHub App Token|ghs_[A-Za-z0-9]{36,}"
  "GitHub Refresh Token|ghr_[A-Za-z0-9]{36,}"
  "GitHub Fine-Grained PAT|github_pat_[A-Za-z0-9_]{82,}"

  # OpenAI / AI providers
  "OpenAI API Key|sk-[A-Za-z0-9]{20,}"
  "Anthropic API Key|sk-ant-[A-Za-z0-9_-]{20,}"

  # Cloud providers
  "AWS Access Key|AKIA[0-9A-Z]{16}"
  "AWS Secret Key|(?i)aws_secret_access_key\s*[=:]\s*[A-Za-z0-9/+=]{40}"

  # Discord
  "Discord Bot Token|[MN][A-Za-z0-9_-]{23,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,}"
  "Discord Webhook|https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+"

  # Telegram
  "Telegram Bot Token|[0-9]{8,10}:[A-Za-z0-9_-]{35}"

  # Slack
  "Slack Bot Token|xoxb-[0-9A-Za-z-]+"
  "Slack Webhook|https://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+"

  # ElevenLabs
  "ElevenLabs API Key|(?i)xi-api-key\s*[=:]\s*[A-Za-z0-9]{32,}"

  # Generic dangerous patterns
  "Private Key Header|-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"
  "Generic Secret Assignment|(?i)(secret|password|passwd|token|api_key|apikey)\s*[=:]\s*['\"][A-Za-z0-9+/=_-]{16,}['\"]"
)

# ─── Files to skip ───────────────────────────────────────────────

SKIP_PATTERNS=(
  '\.lock$'
  '\.min\.js$'
  '\.map$'
  'node_modules/'
  'package-lock\.json$'
  'yarn\.lock$'
  '\.png$|\.jpg$|\.gif$|\.ico$|\.woff'
  'pre-commit-secret-check\.sh$'   # don't flag ourselves
)

should_skip() {
  local file="$1"
  for pat in "${SKIP_PATTERNS[@]}"; do
    if echo "$file" | grep -qE "$pat"; then
      return 0
    fi
  done
  return 1
}

# ─── Scan Logic ──────────────────────────────────────────────────

FOUND=0
FINDINGS=()

scan_content() {
  local label="$1" file="$2" content="$3" regex="$4"

  # Use grep -P for Perl regex (supports (?i) lookaheads), fall back to -E
  local matches
  matches=$(echo "$content" | grep -nP "$regex" 2>/dev/null || echo "$content" | grep -nE "$regex" 2>/dev/null || true)

  if [[ -n "$matches" ]]; then
    while IFS= read -r match; do
      [[ -z "$match" ]] && continue
      local lineno="${match%%:*}"
      local line="${match#*:}"
      # Truncate long lines and mask the actual secret
      local masked
      masked=$(echo "$line" | head -c 120 | sed -E 's/(ghu_|ghp_|gho_|ghs_|ghr_|github_pat_|sk-|sk-ant-|AKIA|xoxb-|-----BEGIN)([A-Za-z0-9_+/=-]{4})[A-Za-z0-9_+/=-]*/\1\2***REDACTED***/g')

      FINDINGS+=("$(printf "  ${RED}⛔${RST} ${BLD}%s${RST}\n     File: ${YEL}%s${RST}:%s\n     Match: ${DIM}%s${RST}\n" "$label" "$file" "$lineno" "$masked")")
      FOUND=$((FOUND + 1))
    done <<< "$matches"
  fi
}

scan_file_content() {
  local file="$1" content="$2"
  for entry in "${PATTERNS[@]}"; do
    local label="${entry%%|*}"
    local regex="${entry#*|}"
    scan_content "$label" "$file" "$content" "$regex"
  done
}

# ─── Modes ────────────────────────────────────────────────────────

MODE="staged"
DIFF_REF=""

case "${1:-}" in
  --all)   MODE="all" ;;
  --diff)  MODE="diff"; DIFF_REF="${2:-HEAD~1}" ;;
  --help|-h)
    sed -n '2,/^[^#]/{ s/^# \?//; /^$/q; p }' "$0"; exit 0 ;;
esac

echo ""
echo -e "  ${BLD}🔒 Secret Scanner${RST}"

if [[ "$MODE" == "staged" ]]; then
  echo -e "  ${DIM}Scanning staged files...${RST}"
  echo ""

  # Get list of staged files (added or modified)
  files=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)

  if [[ -z "$files" ]]; then
    echo -e "  ${GRN}✅ No staged files to scan${RST}\n"
    exit 0
  fi

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    should_skip "$file" && continue

    # Get staged content (not working tree)
    content=$(git show ":$file" 2>/dev/null || true)
    [[ -z "$content" ]] && continue

    scan_file_content "$file" "$content"
  done <<< "$files"

elif [[ "$MODE" == "all" ]]; then
  echo -e "  ${DIM}Scanning entire repository...${RST}"
  echo ""

  git ls-files 2>/dev/null | while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    should_skip "$file" && continue
    [[ -f "$file" ]] || continue

    content=$(cat "$file" 2>/dev/null || true)
    [[ -z "$content" ]] && continue

    scan_file_content "$file" "$content"
  done

elif [[ "$MODE" == "diff" ]]; then
  echo -e "  ${DIM}Scanning changes since ${DIFF_REF}...${RST}"
  echo ""

  diff_content=$(git diff "$DIFF_REF" 2>/dev/null || true)
  if [[ -n "$diff_content" ]]; then
    # Extract added lines only (lines starting with +, excluding +++ headers)
    current_file=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^diff\ --git\ a/(.+)\ b/ ]]; then
        current_file="${BASH_REMATCH[1]}"
      elif [[ "$line" =~ ^\+[^+] && -n "$current_file" ]]; then
        should_skip "$current_file" && continue
        added="${line:1}"
        for entry in "${PATTERNS[@]}"; do
          local_label="${entry%%|*}"
          local_regex="${entry#*|}"
          if echo "$added" | grep -qP "$local_regex" 2>/dev/null || echo "$added" | grep -qE "$local_regex" 2>/dev/null; then
            masked=$(echo "$added" | head -c 120 | sed -E 's/(ghu_|ghp_|sk-)[A-Za-z0-9_+/=-]{4}[A-Za-z0-9_+/=-]*/\1****REDACTED****/g')
            FINDINGS+=("$(printf "  ${RED}⛔${RST} ${BLD}%s${RST}\n     File: ${YEL}%s${RST}\n     Match: ${DIM}%s${RST}\n" "$local_label" "$current_file" "$masked")")
            FOUND=$((FOUND + 1))
          fi
        done
      fi
    done <<< "$diff_content"
  fi
fi

# ─── Report ───────────────────────────────────────────────────────

if [[ $FOUND -gt 0 ]]; then
  echo -e "  ${RED}${BLD}🚨 SECRETS DETECTED — COMMIT BLOCKED${RST}\n"

  for finding in "${FINDINGS[@]}"; do
    echo -e "$finding"
  done

  echo -e "  ${YEL}${BLD}What to do:${RST}"
  echo -e "  1. Remove the secret from your code"
  echo -e "  2. Use environment variables or Docker secrets instead"
  echo -e "  3. If this is a false positive, use: ${DIM}git commit --no-verify${RST}"
  echo -e "  4. Add the file to .gitignore if it should never be tracked"
  echo ""
  echo -e "  ${RED}${BLD}$FOUND secret(s) found. Commit aborted.${RST}"
  echo ""
  exit 1
else
  echo -e "  ${GRN}✅ No secrets detected. Clean to commit.${RST}\n"
  exit 0
fi
