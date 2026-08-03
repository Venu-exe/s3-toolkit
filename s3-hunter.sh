#!/usr/bin/env bash
#
# s3-hunter.sh — S3 bucket enumeration + inspection tool (lazys3-style).
# v3.0
#
# Generates common bucket-name permutations for a keyword, checks each
# one against S3 to see if it exists / is publicly accessible, and for
# buckets that ARE publicly accessible, optionally goes a step further:
#   - lists top-level object keys (if ListBucket is allowed anonymously)
#   - reports on ACL / bucket-policy exposure (read/write signals only —
#     this never downloads object contents or writes anything)
#
# IMPORTANT: Only run this against domains/keywords you own or are
# authorized to test. Unauthorized scanning of third-party infrastructure
# may violate acceptable-use policies or the law.
#
# Usage:
#   ./s3-hunter.sh keyword
#   ./s3-hunter.sh keyword -w custom-wordlist.txt
#   ./s3-hunter.sh keyword -t 20                # parallel threads (default 10)
#   ./s3-hunter.sh keyword --inspect             # enable deep inspection of public buckets
#   ./s3-hunter.sh keyword --inspect --max-keys 50
#   ./s3-hunter.sh keyword --inspect -o report.json
#
set -uo pipefail

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""; C_DIM=""
fi

KEYWORD=""
WORDLIST=""
THREADS=10
INSPECT=0
MAX_KEYS=20
OUTFILE=""

usage() {
  echo "Usage: $0 <keyword> [-w wordlist.txt] [-t threads] [--inspect] [--max-keys N] [-o report.json]"
  echo ""
  echo "  keyword       Base word to permute (e.g. company name, domain)"
  echo "  -w wordlist   Custom list of prefixes/suffixes (one per line)"
  echo "  -t threads    Number of parallel checks (default: 10)"
  echo "  --inspect     For each publicly-readable bucket found, list up to"
  echo "                --max-keys top-level object keys and check for a"
  echo "                public/writable ACL or bucket policy. Read-only —"
  echo "                never downloads object bodies or writes to a bucket."
  echo "  --max-keys N  Max object keys to list per bucket when --inspect is on (default: 20)"
  echo "  -o file       Write a machine-readable JSON report to file"
  echo ""
  echo "  Only use against targets you own or are authorized to test."
  exit "${1:-0}"
}

[[ $# -eq 0 ]] && usage 1

KEYWORD="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w) WORDLIST="$2"; shift 2 ;;
    -t) THREADS="$2"; shift 2 ;;
    --inspect) INSPECT=1; shift ;;
    --max-keys) MAX_KEYS="$2"; shift 2 ;;
    -o) OUTFILE="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1"; usage 1 ;;
  esac
done

# ---------- Built-in default wordlist (common bucket-naming patterns) ----------
DEFAULT_WORDS=(
  "" "www" "dev" "test" "staging" "prod" "production" "beta"
  "backup" "backups" "bak" "old" "archive" "data" "files"
  "assets" "static" "media" "uploads" "downloads" "images" "img"
  "cdn" "public" "private" "internal" "secure" "secret" "confidential"
  "api" "app" "apps" "web" "site" "admin" "config" "conf"
  "db" "database" "logs" "log" "temp" "tmp" "cache"
  "s3" "storage" "cloud" "assets-dev" "assets-prod"
  "us" "eu" "east" "west" "east1" "west1" "east2" "west2"
  "01" "02" "1" "2" "team" "corp" "inc" "co"
  "resources" "content" "content-dev" "content-prod"
)

if [[ -n "$WORDLIST" ]]; then
  mapfile -t WORDS < "$WORDLIST"
else
  WORDS=("${DEFAULT_WORDS[@]}")
fi

# ---------- Generate candidate bucket names ----------
CANDIDATES_FILE=$(mktemp)

# Always test the bare keyword itself first — this is what lazys3 does,
# and it's easy to miss if a custom wordlist has no blank line in it.
echo "$KEYWORD" >> "$CANDIDATES_FILE"

for w in "${WORDS[@]}"; do
  [[ -z "$w" ]] && continue
  echo "${KEYWORD}-${w}" >> "$CANDIDATES_FILE"
  echo "${KEYWORD}.${w}" >> "$CANDIDATES_FILE"
  echo "${KEYWORD}${w}" >> "$CANDIDATES_FILE"
  echo "${w}-${KEYWORD}" >> "$CANDIDATES_FILE"
  echo "${w}.${KEYWORD}" >> "$CANDIDATES_FILE"
  echo "${w}${KEYWORD}" >> "$CANDIDATES_FILE"
done

sort -u -o "$CANDIDATES_FILE" "$CANDIDATES_FILE"
TOTAL=$(wc -l < "$CANDIDATES_FILE")

echo "${C_CYAN}${C_BOLD}S3 Hunter v3.0${C_RESET} — keyword: ${C_BOLD}${KEYWORD}${C_RESET} | candidates: ${TOTAL} | threads: ${THREADS} | inspect: $([[ $INSPECT -eq 1 ]] && echo on || echo off)"
echo ""

RESULTS_DIR=$(mktemp -d)
export RESULTS_DIR

# ---------- Helpers for JSON-safe strings ----------
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
export -f json_escape

# ---------- Inspection: list top-level object keys (anonymous ListBucket) ----------
list_bucket_keys() {
  local bucket="$1" base_url="$2"
  local list_url="${base_url}/?list-type=2&max-keys=${MAX_KEYS}"
  local xml
  xml=$(curl -s -m 8 "$list_url" 2>/dev/null)

  # If listing isn't allowed we'll get an AccessDenied/NoSuchBucket XML body,
  # not a <Key> list — detect that and bail out quietly.
  if ! grep -q "<Key>" <<< "$xml"; then
    return 1
  fi

  echo -e "  ${C_DIM}listable objects (top ${MAX_KEYS}):${C_RESET}"
  grep -o "<Key>[^<]*</Key>" <<< "$xml" | sed -e 's/<Key>//' -e 's#</Key>##' | while IFS= read -r key; do
    echo "    - $key"
  done
  return 0
}
export -f list_bucket_keys

# ---------- Inspection: public ACL / policy signals (read-only checks) ----------
check_exposure() {
  local bucket="$1" base_url="$2"
  local acl_code acl_body policy_code notes=""

  # Anonymous read of the ACL sub-resource. Only succeeds if the bucket
  # grants READ_ACP to Everyone/AuthenticatedUsers, which itself is a
  # misconfiguration signal worth surfacing.
  acl_body=$(curl -s -m 8 -w "\n%{http_code}" "${base_url}/?acl" 2>/dev/null)
  acl_code=$(tail -n1 <<< "$acl_body")
  acl_body=$(sed '$d' <<< "$acl_body")

  if [[ "$acl_code" == "200" ]]; then
    if grep -q "AllUsers" <<< "$acl_body" && grep -qi "WRITE" <<< "$acl_body"; then
      notes+="ACL grants WRITE to AllUsers (anyone can upload/overwrite objects); "
    fi
    if grep -q "AllUsers" <<< "$acl_body" && grep -qi "READ" <<< "$acl_body"; then
      notes+="ACL grants READ to AllUsers; "
    fi
    if grep -q "AllUsers" <<< "$acl_body" && grep -qi "WRITE_ACP\|FULL_CONTROL" <<< "$acl_body"; then
      notes+="ACL grants permission-management rights to AllUsers; "
    fi
  fi

  # Anonymous read of the bucket policy sub-resource — presence alone
  # doesn't mean it's permissive, but an anonymously-readable policy
  # combined with a 200 on the base URL is worth flagging for manual review.
  policy_code=$(curl -s -o /dev/null -m 8 -w "%{http_code}" "${base_url}/?policy" 2>/dev/null)
  if [[ "$policy_code" == "200" ]]; then
    notes+="bucket policy document is anonymously readable; "
  fi

  printf '%s' "$notes"
}
export -f check_exposure

# ---------- Check function ----------
check_one() {
  local bucket="$1"

  # S3 bucket names must be valid DNS labels; skip obviously invalid ones
  if [[ ! "$bucket" =~ ^[a-z0-9.-]{3,63}$ ]]; then
    return
  fi

  # Bucket names containing dots break SSL cert validation on the
  # virtual-hosted style URL (bucket.name.s3.amazonaws.com), because
  # AWS's wildcard cert only covers *.s3.amazonaws.com (one subdomain
  # level). Use path-style instead for those to avoid false negatives.
  local base_url
  if [[ "$bucket" == *.* ]]; then
    base_url="https://s3.amazonaws.com/${bucket}"
  else
    base_url="https://${bucket}.s3.amazonaws.com"
  fi

  local code
  code=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "$base_url" 2>/dev/null)

  local status="" note=""
  case "$code" in
    200)
      status="PUBLIC"
      echo -e "${C_GREEN}[FOUND - PUBLIC] ${bucket} (200)${C_RESET}"
      if [[ "$INSPECT" -eq 1 ]]; then
        list_bucket_keys "$bucket" "$base_url"
        note=$(check_exposure "$bucket" "$base_url")
        if [[ -n "$note" ]]; then
          echo -e "  ${C_RED}exposure: ${note}${C_RESET}"
        fi
      fi
      ;;
    403)
      status="PRIVATE"
      echo -e "${C_YELLOW}[FOUND - PRIVATE] ${bucket} (403)${C_RESET}"
      if [[ "$INSPECT" -eq 1 ]]; then
        # Bucket exists but base GET is denied — ACL/policy might still be
        # anonymously readable (a common misconfig), so check regardless.
        note=$(check_exposure "$bucket" "$base_url")
        if [[ -n "$note" ]]; then
          echo -e "  ${C_RED}exposure: ${note}${C_RESET}"
        fi
      fi
      ;;
    404) return ;; # doesn't exist — stay quiet
    000)
      echo -e "${C_RED}[ERROR] ${bucket} (no response / network or SSL issue)${C_RESET}"
      return
      ;;
    *)
      echo -e "${bucket} (${code})"
      return
      ;;
  esac

  # Persist a per-bucket JSON fragment for the optional report; safe even
  # when -o wasn't passed, we just won't assemble it into a final file.
  {
    printf '{"bucket":"%s","status":"%s","http_code":"%s","url":"%s","exposure":"%s"}\n' \
      "$(json_escape "$bucket")" "$status" "$code" "$(json_escape "$base_url")" "$(json_escape "$note")"
  } >> "${RESULTS_DIR}/results.ndjson"
}
export -f check_one
export C_GREEN C_YELLOW C_RED C_DIM C_RESET INSPECT MAX_KEYS

# ---------- Run checks in parallel ----------
if command -v xargs >/dev/null 2>&1; then
  cat "$CANDIDATES_FILE" | xargs -P "$THREADS" -I{} bash -c 'check_one "$@"' _ {}
else
  while IFS= read -r bucket; do
    check_one "$bucket"
  done < "$CANDIDATES_FILE"
fi

rm -f "$CANDIDATES_FILE"

# ---------- Assemble optional JSON report ----------
if [[ -n "$OUTFILE" ]]; then
  {
    echo "{"
    printf '  "keyword": "%s",\n' "$(json_escape "$KEYWORD")"
    printf '  "generated": "%s",\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '  "inspect": %s,\n' "$([[ $INSPECT -eq 1 ]] && echo true || echo false)"
    echo '  "results": ['
    if [[ -f "${RESULTS_DIR}/results.ndjson" ]]; then
      paste -sd ',' "${RESULTS_DIR}/results.ndjson" 2>/dev/null | sed 's/^/    /'
    fi
    echo '  ]'
    echo "}"
  } > "$OUTFILE"
  echo ""
  echo "${C_CYAN}Report written to ${OUTFILE}${C_RESET}"
fi

rm -rf "$RESULTS_DIR"

echo ""
echo "${C_CYAN}Done.${C_RESET}"