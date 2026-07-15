#!/usr/bin/env bash
#
# s3-finder.sh — Search AWS S3 buckets and objects by name pattern.
#
# Requirements:
#   - AWS CLI v2 installed and configured (aws configure / env vars / profile)
#   - jq (required for parsing results)
#
# Usage:
#   ./s3-finder.sh                          # interactive menu (easiest for clients)
#   ./s3-finder.sh [OPTIONS] <search-pattern>
#
# Options:
#   -b, --bucket BUCKET   Limit search to a single bucket (skips bucket discovery)
#   -p, --profile PROFILE AWS CLI profile to use
#   -r, --region REGION   AWS region to use
#   -e, --ext EXTENSION   Only match keys ending in this extension (e.g. .log)
#   -c, --case-sensitive  Case-sensitive match (default is case-insensitive)
#   -j, --json            Output raw JSON lines instead of a formatted table
#   -m, --max NUMBER      Max results per bucket (default: no limit)
#   -d, --domain          Domain mode: pattern is treated as a domain
#                          (e.g. example.com) and matches that domain,
#                          its subdomains, and www-prefixed keys/buckets.
#   --preset NAME         Use a built-in command pattern (see PRESETS below).
#   -h, --help            Show this help message
#
# Built-in presets (run: ./s3-finder.sh --preset list):
#   invoices    -> ext .pdf, pattern "invoice"
#   images      -> ext .jpg (also searches .png/.jpeg separately)
#   logs        -> ext .log
#   backups     -> pattern "backup"
#   domains     -> domain mode prompt
#
# Examples:
#   ./s3-finder.sh invoice
#   ./s3-finder.sh -b my-bucket -e .csv report
#   ./s3-finder.sh -p prod -r us-east-1 "2024-01"
#   ./s3-finder.sh -d example.com          # find everything for a domain/client
#   ./s3-finder.sh --preset invoices
#
set -euo pipefail

# ---------- Defaults ----------
PATTERN=""
BUCKET=""
PROFILE=""
REGION=""
EXTENSION=""
CASE_SENSITIVE=0
JSON_OUTPUT=0
MAX_RESULTS=0
DOMAIN_MODE=0
PRESET=""

# ---------- Colors ----------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_CYAN=$'\033[36m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET="" C_BOLD="" C_GREEN="" C_CYAN="" C_YELLOW="" C_RED=""
fi

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

log_err() {
  echo "${C_RED}Error:${C_RESET} $*" >&2
}

# ---------- Built-in command patterns (presets) ----------
# Each preset sets: PATTERN / EXTENSION / DOMAIN_MODE for a common client task.
apply_preset() {
  local name="$1"
  case "$name" in
    list)
      cat >&2 <<EOF
${C_BOLD}Available presets:${C_RESET}
  invoices  - find PDF invoices                 (ext .pdf, pattern "invoice")
  images    - find image files                  (ext .jpg/.jpeg/.png)
  logs      - find log files                    (ext .log)
  backups   - find backup files                 (pattern "backup")
  domains   - search everything for a domain    (prompts for domain)
EOF
      exit 0
      ;;
    invoices)
      EXTENSION=".pdf"
      [[ -z "$PATTERN" ]] && PATTERN="invoice"
      ;;
    images)
      EXTENSION=".jpg"
      [[ -z "$PATTERN" ]] && PATTERN="."
      ;;
    logs)
      EXTENSION=".log"
      [[ -z "$PATTERN" ]] && PATTERN="."
      ;;
    backups)
      [[ -z "$PATTERN" ]] && PATTERN="backup"
      ;;
    domains)
      DOMAIN_MODE=1
      if [[ -z "$PATTERN" ]]; then
        read -rp "Enter domain to search for (e.g. example.com): " PATTERN
      fi
      ;;
    *)
      log_err "Unknown preset: $name (try --preset list)"
      exit 1
      ;;
  esac
}

# ---------- Interactive menu (no args needed — good for clients) ----------
run_interactive_menu() {
  echo "${C_BOLD}${C_CYAN}=== S3 Finder — Interactive Mode ===${C_RESET}"
  echo ""
  echo "What would you like to search for?"
  echo "  1) A domain / client (all files matching a domain name)"
  echo "  2) Invoices (PDF)"
  echo "  3) Images (jpg/jpeg/png)"
  echo "  4) Log files"
  echo "  5) Backups"
  echo "  6) Custom search (enter your own text/pattern)"
  echo ""
  read -rp "Choose an option [1-6]: " choice
  echo ""

  case "$choice" in
    1)
      read -rp "Enter domain (e.g. example.com): " PATTERN
      DOMAIN_MODE=1
      ;;
    2)
      apply_preset invoices
      ;;
    3)
      apply_preset images
      ;;
    4)
      apply_preset logs
      ;;
    5)
      apply_preset backups
      ;;
    6)
      read -rp "Enter search text/pattern: " PATTERN
      ;;
    *)
      log_err "Invalid choice."
      exit 1
      ;;
  esac

  read -rp "Limit to a single bucket? (leave blank to search all): " BUCKET
  read -rp "AWS profile to use? (leave blank for default): " PROFILE
  echo ""
}

# ---------- Argument parsing ----------
if [[ $# -eq 0 ]]; then
  run_interactive_menu
else
  ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--bucket)
        BUCKET="$2"; shift 2 ;;
      -p|--profile)
        PROFILE="$2"; shift 2 ;;
      -r|--region)
        REGION="$2"; shift 2 ;;
      -e|--ext)
        EXTENSION="$2"; shift 2 ;;
      -c|--case-sensitive)
        CASE_SENSITIVE=1; shift ;;
      -j|--json)
        JSON_OUTPUT=1; shift ;;
      -m|--max)
        MAX_RESULTS="$2"; shift 2 ;;
      -d|--domain)
        DOMAIN_MODE=1; shift ;;
      --preset)
        PRESET="$2"; shift 2 ;;
      -h|--help)
        usage 0 ;;
      --)
        shift; ARGS+=("$@"); break ;;
      -*)
        log_err "Unknown option: $1"
        usage 1 ;;
      *)
        ARGS+=("$1"); shift ;;
    esac
  done

  if [[ -n "$PRESET" ]]; then
    [[ ${#ARGS[@]} -gt 0 ]] && PATTERN="${ARGS[0]}"
    apply_preset "$PRESET"
  elif [[ ${#ARGS[@]} -gt 0 ]]; then
    PATTERN="${ARGS[0]}"
  fi

  if [[ -z "$PATTERN" ]]; then
    log_err "Missing search pattern."
    usage 1
  fi
fi

# Domain mode: build a regex that matches the domain itself, subdomains,
# and www-prefixed versions (e.g. "example.com" also matches
# "sub.example.com", "www.example.com", "example.com/path...").
if [[ "$DOMAIN_MODE" -eq 1 ]]; then
  ESCAPED_DOMAIN=$(printf '%s' "$PATTERN" | sed 's/[.[\*^$/]/\\&/g')
  PATTERN="([a-zA-Z0-9-]+\\.)*${ESCAPED_DOMAIN}"
fi

# ---------- Preflight checks ----------
if ! command -v aws >/dev/null 2>&1; then
  log_err "AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  exit 1
fi

AWS_ARGS=()
[[ -n "$PROFILE" ]] && AWS_ARGS+=(--profile "$PROFILE")
[[ -n "$REGION" ]] && AWS_ARGS+=(--region "$REGION")

if ! aws sts get-caller-identity "${AWS_ARGS[@]}" >/dev/null 2>&1; then
  log_err "AWS credentials are not valid or not configured. Run 'aws configure' or check your profile/env vars."
  exit 1
fi

# ---------- Get list of buckets to search ----------
declare -a BUCKETS
if [[ -n "$BUCKET" ]]; then
  BUCKETS=("$BUCKET")
else
  echo "${C_CYAN}Discovering buckets...${C_RESET}" >&2
  mapfile -t BUCKETS < <(aws s3api list-buckets "${AWS_ARGS[@]}" --query 'Buckets[].Name' --output text | tr '\t' '\n')
  if [[ ${#BUCKETS[@]} -eq 0 ]]; then
    log_err "No buckets found or insufficient permissions to list buckets."
    exit 1
  fi
fi

echo "${C_CYAN}Searching ${#BUCKETS[@]} bucket(s) for pattern: ${C_BOLD}${PATTERN}${C_RESET}" >&2
[[ -n "$EXTENSION" ]] && echo "${C_CYAN}Filtering by extension: ${EXTENSION}${C_RESET}" >&2
echo "" >&2

# ---------- Search buckets/objects ----------
TOTAL_MATCHES=0

# Build the grep flags based on case sensitivity
GREP_FLAGS="-E"
[[ "$CASE_SENSITIVE" -eq 0 ]] && GREP_FLAGS="${GREP_FLAGS}i"

if [[ "$JSON_OUTPUT" -eq 0 ]]; then
  printf "%s%-30s %12s  %-19s  %s%s\n" "$C_BOLD" "BUCKET" "SIZE" "LAST MODIFIED" "KEY" "$C_RESET"
  printf '%s\n' "--------------------------------------------------------------------------------------------"
fi

for b in "${BUCKETS[@]}"; do
  # Skip buckets we can't access rather than aborting the whole run
  if ! aws s3api head-bucket --bucket "$b" "${AWS_ARGS[@]}" >/dev/null 2>&1; then
    continue
  fi

  # Paginate through objects
  LIST_ARGS=(s3api list-objects-v2 --bucket "$b" "${AWS_ARGS[@]}" --output json)
  if [[ "$MAX_RESULTS" -gt 0 ]]; then
    LIST_ARGS+=(--max-items "$MAX_RESULTS")
  fi

  OBJECTS_JSON=$(aws "${LIST_ARGS[@]}" 2>/dev/null || echo '{}')

  MATCHES=$(echo "$OBJECTS_JSON" | jq -r --arg pat "$PATTERN" --arg ext "$EXTENSION" '
    (.Contents // [])[]
    | select(($ext == "") or (.Key | endswith($ext)))
    | [.Key, (.Size|tostring), .LastModified]
    | @tsv
  ' 2>/dev/null || true)

  [[ -z "$MATCHES" ]] && continue

  while IFS=$'\t' read -r key size lastmod; do
    [[ -z "$key" ]] && continue
    if echo "$key" | grep -q $GREP_FLAGS -- "$PATTERN"; then
      TOTAL_MATCHES=$((TOTAL_MATCHES + 1))
      HUMAN_SIZE=$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size}B")
      SHORT_DATE="${lastmod:0:19}"
      if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        printf '{"bucket":"%s","key":"%s","size":%s,"last_modified":"%s"}\n' "$b" "$key" "$size" "$lastmod"
      else
        printf "%-30s %12s  %-19s  %s%s%s\n" "$b" "$HUMAN_SIZE" "$SHORT_DATE" "$C_GREEN" "$key" "$C_RESET"
      fi
    fi
  done <<< "$MATCHES"

  # Also flag it if the bucket's own name matches (common when buckets
  # are named after a client/domain, e.g. "example-com-assets")
  if echo "$b" | grep -q $GREP_FLAGS -- "$PATTERN"; then
    TOTAL_MATCHES=$((TOTAL_MATCHES + 1))
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
      printf '{"bucket":"%s","key":null,"match_type":"bucket_name"}\n' "$b"
    else
      printf "%-30s %12s  %-19s  %s(bucket name match)%s\n" "$b" "-" "-" "$C_YELLOW" "$C_RESET"
    fi
  fi
done

echo "" >&2
if [[ "$TOTAL_MATCHES" -eq 0 ]]; then
  echo "${C_YELLOW}No matches found for '${PATTERN}'.${C_RESET}" >&2
else
  echo "${C_GREEN}Found ${TOTAL_MATCHES} matching object(s).${C_RESET}" >&2
fi
