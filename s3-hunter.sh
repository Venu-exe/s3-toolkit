#!/usr/bin/env bash
#
# s3-hunter-v3.sh — S3 Hunter, advanced edition (v3.0.0)
#
# A much more capable evolution of s3-hunter.sh: smarter permutation modes,
# accurate bucket-state classification (not just raw HTTP codes), JSON/CSV
# output, retries with backoff, optional public-object listing, an opt-in
# public-write misconfiguration test, and support for S3-compatible
# endpoints beyond AWS.
#
# IMPORTANT: Only run this against domains/keywords you own or are
# authorized to test (e.g. in-scope for a bug bounty program). Unauthorized
# scanning of third-party infrastructure may violate acceptable-use
# policies or the law. See --help and the README for details.
#
# Usage:
#   ./s3-hunter-v3.sh keyword
#   ./s3-hunter-v3.sh keyword -m deep -W -t 25 --check-write
#   ./s3-hunter-v3.sh keyword -f json -o results.json --list-objects
#

set -uo pipefail

VERSION="3.0.0"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
KEYWORD=""
WORDLIST=""
USE_BIG_WORDLIST=false
MODE="standard"          # quick | standard | deep
THREADS=15
TIMEOUT=6
RETRIES=1
DELAY_MS=0
RATE=""
OUTPUT=""
FORMAT="text"            # text | json | csv
LIST_OBJECTS=false
LIST_LIMIT=10
CHECK_WRITE=false
ENDPOINT_TEMPLATE=""
RESUME_FILE=""
ASSUME_YES=false
VERBOSE=false
NO_COLOR=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Fallback word list if nothing else is available (mirrors v1's built-in list)
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

# Small, highest-signal list for --mode quick
QUICK_WORDS=(
  "" "www" "dev" "test" "staging" "prod" "backup" "backups" "data"
  "files" "assets" "static" "uploads" "media" "logs" "config" "admin"
  "api" "archive" "old" "temp"
)

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
S3 Hunter v${VERSION} (advanced) — S3 bucket enumeration & misconfiguration scanner

Usage:
  $0 <keyword> [options]

Positional:
  keyword                  Base word to permute (company name, domain, etc.)

Wordlist / permutations:
  -w, --wordlist FILE      Custom wordlist (one word per line)
  -W, --big-wordlist       Force the bundled larger wordlist (advanced-bucket-words.txt)
  -m, --mode MODE          quick | standard | deep   (default: standard)
                              quick    - ~20 highest-signal words, fastest
                              standard - full bundled wordlist, v1-style patterns
                              deep     - standard + '_' separator + year/number suffixes

Performance:
  -t, --threads N          Parallel workers (default: 15, capped at 50)
      --timeout N           Per-request timeout in seconds (default: 6)
      --retries N           Retries on network/5xx errors (default: 1)
      --delay MS            Delay before each request, per worker, in ms (default: 0)
      --rate N              Approx. global requests/sec (overrides --delay)

Output:
  -o, --output FILE        Write results to FILE
  -f, --format FMT         text | json | csv   (default: text)
  -v, --verbose             Also show not-found / redirect / error lines
      --no-color            Disable ANSI colors

Deeper checks (opt-in, ACTIVE tests — not passive recon):
      --list-objects        List first objects found inside PUBLIC buckets
      --list-limit N        Max objects to list per bucket (default: 10)
      --check-write         Test whether buckets accept unauthenticated writes
                               (uploads then deletes one small labeled test object)

Misc:
      --endpoint TEMPLATE   Custom endpoint template for S3-compatible storage,
                               '{bucket}' is replaced, e.g.:
                               'https://{bucket}.nyc3.digitaloceanspaces.com'
      --resume FILE         Skip bucket names already present in FILE
  -y, --yes                 Skip interactive authorization prompts
      --version              Print version and exit
  -h, --help                 Show this help and exit

Examples:
  $0 mycompany
  $0 mycompany -m deep -W -t 25 --check-write
  $0 mycompany -f json -o results.json --list-objects

  Only use against targets you own or are authorized to test.
EOF
  exit "${1:-0}"
}

[[ $# -eq 0 ]] && usage 1

KEYWORD="$1"; shift
if [[ "$KEYWORD" == -* ]]; then
  echo "Error: keyword must come first, got option-like value '$KEYWORD'" >&2
  usage 1
fi
KEYWORD="${KEYWORD,,}"   # S3 bucket names are lowercase-only

if [[ ! "$KEYWORD" =~ ^[a-z0-9.-]+$ ]]; then
  echo "Warning: keyword contains characters outside [a-z0-9.-] — most generated candidates will be invalid S3 names and skipped." >&2
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--wordlist)      WORDLIST="$2"; shift 2 ;;
    -W|--big-wordlist)  USE_BIG_WORDLIST=true; shift ;;
    -m|--mode)          MODE="$2"; shift 2 ;;
    -t|--threads)       THREADS="$2"; shift 2 ;;
    --timeout)          TIMEOUT="$2"; shift 2 ;;
    --retries)          RETRIES="$2"; shift 2 ;;
    --delay)            DELAY_MS="$2"; shift 2 ;;
    --rate)             RATE="$2"; shift 2 ;;
    -o|--output)         OUTPUT="$2"; shift 2 ;;
    -f|--format)         FORMAT="$2"; shift 2 ;;
    -v|--verbose)         VERBOSE=true; shift ;;
    --no-color)           NO_COLOR=true; shift ;;
    --list-objects)       LIST_OBJECTS=true; shift ;;
    --list-limit)         LIST_LIMIT="$2"; shift 2 ;;
    --check-write)        CHECK_WRITE=true; shift ;;
    --endpoint)           ENDPOINT_TEMPLATE="$2"; shift 2 ;;
    --resume)             RESUME_FILE="$2"; shift 2 ;;
    -y|--yes)              ASSUME_YES=true; shift ;;
    --version)             echo "s3-hunter v${VERSION}"; exit 0 ;;
    -h|--help)              usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
case "$MODE" in quick|standard|deep) ;; *)
  echo "Error: invalid --mode '$MODE' (use quick|standard|deep)" >&2; exit 1 ;;
esac
case "$FORMAT" in text|json|csv) ;; *)
  echo "Error: invalid --format '$FORMAT' (use text|json|csv)" >&2; exit 1 ;;
esac
for n in "$THREADS" "$TIMEOUT" "$RETRIES" "$DELAY_MS" "$LIST_LIMIT"; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "Error: expected a non-negative integer, got '$n'" >&2; exit 1; }
done
(( THREADS < 1 )) && THREADS=1
if (( THREADS > 50 )); then
  echo "Note: capping --threads at 50 to be a reasonable network citizen." >&2
  THREADS=50
fi
if [[ -n "$RATE" ]]; then
  [[ "$RATE" =~ ^[0-9]+$ && "$RATE" -gt 0 ]] || { echo "Error: --rate must be a positive integer" >&2; exit 1; }
  DELAY_MS=$(awk -v t="$THREADS" -v r="$RATE" 'BEGIN{ printf "%.0f", (t*1000.0)/r }')
fi

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
if [[ "$NO_COLOR" != "true" && -t 1 ]]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""
fi

TMPBASE="/tmp"
[[ -d "/dev/shm" && -w "/dev/shm" ]] && TMPBASE="/dev/shm"

note() {
  if [[ "$FORMAT" == "text" ]]; then echo -e "$1"; else echo -e "$1" >&2; fi
}

# ---------------------------------------------------------------------------
# Authorization gate
# ---------------------------------------------------------------------------
if [[ "$ASSUME_YES" != "true" ]]; then
  {
    echo ""
    echo "${C_YELLOW}${C_BOLD}⚠ Scope & Ethics${C_RESET}"
    echo "Only run this against domains/keywords you own or are explicitly"
    echo "authorized to test (e.g. in-scope for a bug bounty program)."
    echo "Unauthorized scanning of third-party infrastructure may violate"
    echo "acceptable-use policies or the law."
    echo "${C_BOLD}Ethical use only · Responsible disclosure · No harm, just protection.${C_RESET}"
    echo ""
  } >&2
  read -r -p "Type 'yes' to confirm you're authorized to test targets derived from '${KEYWORD}': " _confirm
  if [[ "$_confirm" != "yes" ]]; then
    echo "Aborted — authorization not confirmed." >&2
    exit 1
  fi

  if [[ "$CHECK_WRITE" == "true" ]]; then
    {
      echo ""
      echo "${C_RED}${C_BOLD}--check-write is enabled.${C_RESET}"
      echo "This actively uploads and then deletes a small, clearly-labeled test"
      echo "object in every bucket found to exist, to test for public-write"
      echo "misconfigurations. This is an ACTIVE test, not passive recon."
    } >&2
    read -r -p "Type 'yes' to confirm you're authorized to do this: " _confirm2
    if [[ "$_confirm2" != "yes" ]]; then
      echo "Aborted — write-test authorization not confirmed." >&2
      exit 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Wordlist resolution
# ---------------------------------------------------------------------------
resolve_wordlist() {
  if [[ -n "$WORDLIST" ]]; then
    [[ -f "$WORDLIST" ]] || { echo "Error: wordlist file not found: $WORDLIST" >&2; exit 1; }
    mapfile -t WORDS < <(grep -v '^[[:space:]]*$' "$WORDLIST" | tr -d '\r')
    return
  fi

  local big="${SCRIPT_DIR}/advanced-bucket-words.txt"
  local std="${SCRIPT_DIR}/common-bucket-words.txt"

  case "$MODE" in
    quick)
      WORDS=("${QUICK_WORDS[@]}")
      ;;
    deep)
      if [[ -f "$big" ]]; then mapfile -t WORDS < <(grep -v '^[[:space:]]*$' "$big" | tr -d '\r')
      elif [[ -f "$std" ]]; then mapfile -t WORDS < <(grep -v '^[[:space:]]*$' "$std" | tr -d '\r')
      else WORDS=("${DEFAULT_WORDS[@]}")
      fi
      ;;
    *)
      if [[ "$USE_BIG_WORDLIST" == "true" && -f "$big" ]]; then
        mapfile -t WORDS < <(grep -v '^[[:space:]]*$' "$big" | tr -d '\r')
      elif [[ -f "$std" ]]; then
        mapfile -t WORDS < <(grep -v '^[[:space:]]*$' "$std" | tr -d '\r')
      else
        WORDS=("${DEFAULT_WORDS[@]}")
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Candidate generation
# ---------------------------------------------------------------------------
generate_candidates() {
  local out="$1"
  : > "$out"
  echo "$KEYWORD" >> "$out"

  local seps=("-" "." "")
  [[ "$MODE" == "deep" ]] && seps+=("_")

  local w s
  for w in "${WORDS[@]}"; do
    [[ -z "$w" ]] && continue
    for s in "${seps[@]}"; do
      echo "${KEYWORD}${s}${w}" >> "$out"
      echo "${w}${s}${KEYWORD}" >> "$out"
    done
  done

  if [[ "$MODE" == "deep" ]]; then
    local y n
    for y in 19 20 21 22 23 24 25 26; do
      echo "${KEYWORD}20${y}" >> "$out"
      echo "${KEYWORD}-20${y}" >> "$out"
    done
    for n in 01 02 03 04 05 1 2 3 4 5; do
      echo "${KEYWORD}${n}" >> "$out"
      echo "${KEYWORD}-${n}" >> "$out"
    done
  fi

  sort -u -o "$out" "$out"
}

build_skip_set() {
  local f="$1" out="$2"
  awk -F'|' 'NF>1{print $1; next}{print}' "$f" \
    | awk -F',' 'NF>1{print $1; next}{print}' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | grep -vx 'bucket' \
    | sort -u > "$out"
}

# ---------------------------------------------------------------------------
# Per-candidate check (runs in parallel worker subshells via xargs)
# ---------------------------------------------------------------------------
valid_bucket_name() {
  local b="$1" len=${#1}
  (( len < 3 || len > 63 )) && return 1
  [[ "$b" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
  [[ "$b" == *..* ]] && return 1
  [[ "$b" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 1
  return 0
}

build_url() {
  local bucket="$1"
  if [[ -n "$ENDPOINT_TEMPLATE" ]]; then
    printf '%s' "${ENDPOINT_TEMPLATE//\{bucket\}/${bucket}}"
  elif [[ "$bucket" == *.* ]]; then
    printf 'https://s3.amazonaws.com/%s' "$bucket"
  else
    printf 'https://%s.s3.amazonaws.com' "$bucket"
  fi
}

rate_limit_delay() {
  if (( DELAY_MS > 0 )); then
    sleep "$(awk -v m="$DELAY_MS" 'BEGIN{printf "%.3f", m/1000}')"
  fi
}

fetch_with_retry() {
  local url="$1" headers="$2" body="$3"
  local attempt=0 code
  while :; do
    code=$(curl -s -o "$body" -D "$headers" -m "$TIMEOUT" -w '%{http_code}' "$url" 2>/dev/null)
    if [[ "$code" != "000" && ! "$code" =~ ^5[0-9][0-9]$ ]]; then
      printf '%s' "$code"; return
    fi
    attempt=$((attempt + 1))
    (( attempt > RETRIES )) && { printf '%s' "$code"; return; }
    sleep "$attempt"
  done
}

check_write() {
  local bucket="$1" baseurl="$2"
  local key=".s3-toolkit-writetest-$(date +%s)-${RANDOM}"
  local testurl="${baseurl%/}/${key}"
  local putcode
  putcode=$(curl -s -o /dev/null -m "$TIMEOUT" -w '%{http_code}' \
    -X PUT -H "Content-Type: text/plain" \
    --data "s3-toolkit v3 write-permission test -- safe to delete -- $(date -u +%FT%TZ)" \
    "$testurl" 2>/dev/null)
  if [[ "$putcode" == "200" || "$putcode" == "204" ]]; then
    local delcode
    delcode=$(curl -s -o /dev/null -m "$TIMEOUT" -w '%{http_code}' -X DELETE "$testurl" 2>/dev/null)
    if [[ "$delcode" != "200" && "$delcode" != "204" ]]; then
      echo "[WARN] wrote test object ${testurl} but cleanup DELETE returned ${delcode} -- remove manually" >&2
    fi
    printf 'yes'
  else
    printf 'no'
  fi
}

list_object_keys() {
  local bucket="$1" bodyfile="$2"
  local keys
  keys=$(grep -oE '<Key>[^<]*</Key>' "$bodyfile" 2>/dev/null | sed -E 's#</?Key>##g' | head -n "$LIST_LIMIT")
  [[ -z "$keys" ]] && return 0
  echo -e "${C_CYAN}   \xe2\x94\x94\xe2\x94\x80 first objects:${C_RESET}"
  while IFS= read -r k; do
    [[ -n "$k" ]] && echo "        - ${k}"
  done <<< "$keys"
}

print_finding() {
  local bucket="$1" code="$2" cls="$3" region="$4" writable="$5"
  local rs=""
  [[ -n "$region" ]] && rs="  region=${region}"
  case "$cls" in
    PUBLIC)        echo -e "${C_GREEN}[FOUND - PUBLIC]${C_RESET}    ${bucket}   (${code})${rs}" ;;
    PRIVATE)       echo -e "${C_YELLOW}[FOUND - PRIVATE]${C_RESET}   ${bucket}   (${code})${rs}" ;;
    SUSPENDED)     echo -e "${C_YELLOW}[FOUND - SUSPENDED]${C_RESET} ${bucket}   (${code})  bucket exists, access disabled${rs}" ;;
    REDIRECT)      echo -e "${C_CYAN}[REDIRECT]${C_RESET}          ${bucket}   (${code})${rs}" ;;
    NETWORK_ERROR) echo -e "${C_RED}[ERROR]${C_RESET}              ${bucket}   (no response / network or SSL issue)" ;;
    SERVER_ERROR)  echo -e "${C_RED}[SERVER ERROR]${C_RESET}       ${bucket}   (${code})" ;;
    NOT_FOUND)     [[ "$VERBOSE" == "true" ]] && echo "  [not found]              ${bucket}" ;;
    *)             echo "${bucket}   (${code})" ;;
  esac
  if [[ "$writable" == "yes" ]]; then
    echo -e "${C_RED}${C_BOLD}   \xe2\x94\x94\xe2\x94\x80 [CRITICAL] unauthenticated PUBLIC WRITE succeeded on ${bucket}${C_RESET}"
  elif [[ "$writable" == "no" && "$VERBOSE" == "true" ]]; then
    echo "   \xe2\x94\x94\xe2\x94\x80 write test: not writable"
  fi
}

check_one() {
  local bucket="$1"
  valid_bucket_name "$bucket" || return 0

  rate_limit_delay

  local url; url=$(build_url "$bucket")
  local tmpd; tmpd=$(mktemp -d -p "$TMPBASE")
  local headers="$tmpd/headers" body="$tmpd/body"

  local code; code=$(fetch_with_retry "$url" "$headers" "$body")

  local region=""
  [[ -f "$headers" ]] && region=$(grep -i '^x-amz-bucket-region:' "$headers" | tr -d '\r' | awk -F': ' '{print $2}' | head -1)

  local cls="OTHER"
  case "$code" in
    200) cls="PUBLIC" ;;
    403)
      if [[ -f "$body" ]] && grep -qi 'AllAccessDisabled' "$body"; then cls="SUSPENDED"; else cls="PRIVATE"; fi ;;
    404) cls="NOT_FOUND" ;;
    301|307) cls="REDIRECT" ;;
    000) cls="NETWORK_ERROR" ;;
    5[0-9][0-9]) cls="SERVER_ERROR" ;;
    *) cls="OTHER" ;;
  esac

  local writable=""
  if [[ "$CHECK_WRITE" == "true" && ( "$cls" == "PUBLIC" || "$cls" == "PRIVATE" ) ]]; then
    writable=$(check_write "$bucket" "$url")
  fi

  if [[ "$FORMAT" == "text" ]]; then
    print_finding "$bucket" "$code" "$cls" "$region" "$writable"
    [[ "$cls" == "PUBLIC" && "$LIST_OBJECTS" == "true" && -f "$body" ]] && list_object_keys "$bucket" "$body"
  fi

  ( flock -x 201
    printf '%s|%s|%s|%s|%s|%s\n' "$bucket" "$code" "$cls" "$region" "$writable" "$url" >> "$RESULTS_FILE"
  ) 201>>"$RESULTS_LOCK"

  rm -rf "$tmpd"
}

export -f check_one fetch_with_retry valid_bucket_name build_url rate_limit_delay print_finding check_write list_object_keys

# ---------------------------------------------------------------------------
# Report builders (run once, in the main process, after scanning)
# ---------------------------------------------------------------------------
build_text_report() {
  echo "S3 Hunter v${VERSION} -- results for keyword: ${KEYWORD}"
  echo "Generated: $(date -u +%FT%TZ)  |  mode: ${MODE}  |  candidates tested: ${TOTAL}  |  elapsed: ${ELAPSED}s"
  echo ""
  while IFS='|' read -r bucket code cls region writable url; do
    [[ "$cls" == "NOT_FOUND" && "$VERBOSE" != "true" ]] && continue
    local w=""
    [[ "$writable" == "yes" ]] && w="  [WRITABLE]"
    printf '[%s] %-45s (%s)%s%s  %s\n' "$cls" "$bucket" "$code" "${region:+  region=$region}" "$w" "$url"
  done < <(sort -t'|' -k1,1 "$RESULTS_FILE")
}

build_json() {
  local entries=() bucket code cls region writable url
  while IFS='|' read -r bucket code cls region writable url; do
    [[ "$cls" == "NOT_FOUND" && "$VERBOSE" != "true" ]] && continue
    entries+=("$(printf '  {"bucket": "%s", "http_code": "%s", "classification": "%s", "region": "%s", "writable": "%s", "url": "%s"}' \
      "$bucket" "$code" "$cls" "$region" "$writable" "$url")")
  done < <(sort -t'|' -k1,1 "$RESULTS_FILE")

  echo "["
  local n=${#entries[@]} i
  for (( i=0; i<n; i++ )); do
    if (( i < n-1 )); then echo "${entries[$i]},"; else echo "${entries[$i]}"; fi
  done
  echo "]"
}

build_csv() {
  echo "bucket,http_code,classification,region,writable,url"
  while IFS='|' read -r bucket code cls region writable url; do
    [[ "$cls" == "NOT_FOUND" && "$VERBOSE" != "true" ]] && continue
    echo "${bucket},${code},${cls},${region},${writable},${url}"
  done < <(sort -t'|' -k1,1 "$RESULTS_FILE")
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
resolve_wordlist

CANDIDATES_FILE=$(mktemp -p "$TMPBASE")
generate_candidates "$CANDIDATES_FILE"

if [[ -n "$RESUME_FILE" ]]; then
  if [[ -f "$RESUME_FILE" ]]; then
    SKIP_FILE=$(mktemp -p "$TMPBASE")
    build_skip_set "$RESUME_FILE" "$SKIP_FILE"
    if [[ -s "$SKIP_FILE" ]]; then
      FILTERED=$(mktemp -p "$TMPBASE")
      comm -23 "$CANDIDATES_FILE" "$SKIP_FILE" > "$FILTERED"
      mv "$FILTERED" "$CANDIDATES_FILE"
    fi
    rm -f "$SKIP_FILE"
  else
    echo "Warning: --resume file '$RESUME_FILE' not found, ignoring." >&2
  fi
fi

TOTAL=$(wc -l < "$CANDIDATES_FILE")

if (( TOTAL == 0 )); then
  echo "Nothing to test (all candidates already covered by --resume?)." >&2
  rm -f "$CANDIDATES_FILE"
  exit 0
fi

if (( TOTAL > 20000 )) && [[ "$ASSUME_YES" != "true" ]]; then
  echo "${C_YELLOW}This run will test ${TOTAL} candidate names -- that's a lot and may take a