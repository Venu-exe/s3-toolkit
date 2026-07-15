#!/usr/bin/env bash
#
# s3-status.sh — Simple check: is the S3 bucket reachable? Prints HTTP status
# (200, 403, 404, etc.) straight to the screen. No matching, no filtering.
#
# Usage:
#   ./s3-status.sh bucket-name
#   ./s3-status.sh bucket1 bucket2 bucket3
#   ./s3-status.sh -f buckets.txt      # one bucket name per line
#
set -euo pipefail

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
else
  C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""
fi

check_bucket() {
  local bucket="$1"
  local url="https://${bucket}.s3.amazonaws.com"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$url")

  case "$code" in
    200)
      echo "${C_GREEN}${bucket}: ${code} OK${C_RESET}" ;;
    403)
      echo "${C_YELLOW}${bucket}: ${code} Forbidden (exists, no public access)${C_RESET}" ;;
    404)
      echo "${C_RED}${bucket}: ${code} Not Found${C_RESET}" ;;
    *)
      echo "${bucket}: ${code}" ;;
  esac
}

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 bucket-name [bucket-name ...]"
  echo "       $0 -f buckets.txt"
  exit 1
fi

if [[ "$1" == "-f" ]]; then
  file="$2"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    check_bucket "$line"
  done < "$file"
else
  for bucket in "$@"; do
    check_bucket "$bucket"
  done
fi
