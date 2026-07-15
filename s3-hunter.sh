#!/usr/bin/env bash
#
# s3-hunter.sh — S3 bucket enumeration tool (lazys3-style).
# Generates common bucket-name permutations for a keyword and checks
# each one against S3 to see if it exists / is publicly accessible.
#
# IMPORTANT: Only run this against domains/keywords you own or are
# authorized to test. Unauthorized scanning of third-party infrastructure
# may violate acceptable-use policies or the law.
#
# Usage:
#   ./s3-hunter.sh keyword
#   ./s3-hunter.sh keyword -w custom-wordlist.txt
#   ./s3-hunter.sh keyword -t 20        # parallel threads (default 10)
#
set -uo pipefail

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""
fi

KEYWORD=""
WORDLIST=""
THREADS=10

usage() {
  echo "Usage: $0 <keyword> [-w wordlist.txt] [-t threads]"
  echo ""
  echo "  keyword         Base word to permute (e.g. company name, domain)"
  echo "  -w wordlist     Custom list of prefixes/suffixes (one per line)"
  echo "  -t threads      Number of parallel checks (default: 10)"
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
  echo "${KEYWORD}-${w}"  >> "$CANDIDATES_FILE"
  echo "${KEYWORD}.${w}"  >> "$CANDIDATES_FILE"
  echo "${KEYWORD}${w}"   >> "$CANDIDATES_FILE"
  echo "${w}-${KEYWORD}"  >> "$CANDIDATES_FILE"
  echo "${w}.${KEYWORD}"  >> "$CANDIDATES_FILE"
  echo "${w}${KEYWORD}"   >> "$CANDIDATES_FILE"
done
sort -u -o "$CANDIDATES_FILE" "$CANDIDATES_FILE"

TOTAL=$(wc -l < "$CANDIDATES_FILE")
echo "${C_CYAN}${C_BOLD}S3 Hunter${C_RESET} — keyword: ${C_BOLD}${KEYWORD}${C_RESET}  |  candidates: ${TOTAL}  |  threads: ${THREADS}"
echo ""

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
  local url
  if [[ "$bucket" == *.* ]]; then
    url="https://s3.amazonaws.com/${bucket}"
  else
    url="https://${bucket}.s3.amazonaws.com"
  fi

  local code
  code=$(curl -s -o /dev/null -m 5 -w "%{http_code}" "$url" 2>/dev/null)

  case "$code" in
    200)
      echo -e "${C_GREEN}[FOUND - PUBLIC]  ${bucket}  (200)${C_RESET}" ;;
    403)
      echo -e "${C_YELLOW}[FOUND - PRIVATE] ${bucket}  (403)${C_RESET}" ;;
    404) : ;;  # doesn't exist — stay quiet
    000)
      echo -e "${C_RED}[ERROR] ${bucket}  (no response / network or SSL issue)${C_RESET}" ;;
    *)
      echo -e "${bucket}  (${code})" ;;
  esac
}
export -f check_one
export C_GREEN C_YELLOW C_RESET

# ---------- Run checks in parallel ----------
if command -v xargs >/dev/null 2>&1; then
  cat "$CANDIDATES_FILE" | xargs -P "$THREADS" -I{} bash -c 'check_one "$@"' _ {}
else
  while IFS= read -r bucket; do
    check_one "$bucket"
  done < "$CANDIDATES_FILE"
fi

rm -f "$CANDIDATES_FILE"
echo ""
echo "${C_CYAN}Done.${C_RESET}"
