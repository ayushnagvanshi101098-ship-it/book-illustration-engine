#!/usr/bin/env bash
# fal-helpers.sh — Shared FAL API utilities for book illustration engine.
# Source this file, do not execute it directly.
#
# Requires: curl, jq, $FAL_KEY environment variable.
#
# Functions:
#   fal_check_auth        — verify $FAL_KEY is set
#   fal_upload_file       — upload a local file to FAL CDN, print URL
#   fal_upload_zip        — zip a directory and upload, print URL
#   fal_queue_submit      — submit a job to FAL queue, print request_id
#   fal_queue_poll        — poll until COMPLETED or timeout, print status
#   fal_queue_result      — fetch result JSON for a completed request
#   fal_sync_call         — synchronous FAL API call, print response JSON
#   fal_download           — download a URL to a local file

fal_check_auth() {
  if [[ -z "${FAL_KEY:-}" ]]; then
    echo "error: FAL_KEY not set. See .env.example for setup instructions." >&2
    return 1
  fi
  command -v curl >/dev/null || { echo "error: curl not found" >&2; return 1; }
  command -v jq >/dev/null || { echo "error: jq not found" >&2; return 1; }
}

fal_upload_file() {
  local file="$1"
  [[ -f "$file" ]] || { echo "error: file $file not found" >&2; return 1; }

  local mime_type filename
  mime_type=$(file --mime-type -b "$file")
  filename=$(basename "$file")

  # Step 1: Initiate upload — get a signed upload_url and permanent file_url
  local init_resp init_code init_body
  init_resp=$(curl -s -w "\n%{http_code}" -X POST \
    "https://rest.alpha.fal.ai/storage/upload/initiate" \
    -H "Authorization: Key $FAL_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"content_type\": \"$mime_type\", \"file_name\": \"$filename\"}")
  init_code=$(echo "$init_resp" | tail -1)
  init_body=$(echo "$init_resp" | sed '$d')

  if [[ "$init_code" -lt 200 || "$init_code" -ge 300 ]]; then
    echo "error: FAL upload initiate failed (HTTP $init_code): $init_body" >&2
    return 1
  fi

  local upload_url file_url
  upload_url=$(echo "$init_body" | jq -r '.upload_url')
  file_url=$(echo "$init_body" | jq -r '.file_url')

  # Step 2: PUT the file to the signed URL
  local put_code
  put_code=$(curl -s -w "%{http_code}" -X PUT "$upload_url" \
    -H "Content-Type: $mime_type" \
    --data-binary "@$file" -o /dev/null)

  if [[ "$put_code" -lt 200 || "$put_code" -ge 300 ]]; then
    echo "error: FAL upload PUT failed (HTTP $put_code)" >&2
    return 1
  fi

  echo "$file_url"
}

fal_upload_zip() {
  local dir="$1"
  [[ -d "$dir" ]] || { echo "error: directory $dir not found" >&2; return 1; }

  local tmp_zip
  tmp_zip=$(mktemp /tmp/fal-upload-XXXXXX.zip)
  trap "rm -f '$tmp_zip'" RETURN

  # Zip contents of directory (flat, no directory structure)
  # Use find to build file list (avoids zsh glob failures on unmatched extensions)
  local file_list
  file_list=$(find "$dir" -maxdepth 1 \( -name "*.jpeg" -o -name "*.jpg" -o -name "*.png" \) -print)
  if [[ -z "$file_list" ]]; then
    echo "error: no images found in $dir to zip" >&2
    return 1
  fi
  # Remove the empty file mktemp created — zip needs to create it fresh
  rm -f "$tmp_zip"
  (cd "$dir" && find . -maxdepth 1 \( -name "*.jpeg" -o -name "*.jpg" -o -name "*.png" \) -exec zip -q "$tmp_zip" {} +) || {
    echo "error: failed to create zip from $dir" >&2
    return 1
  }

  fal_upload_file "$tmp_zip"
}

fal_queue_submit() {
  local endpoint="$1"
  local payload="$2"

  local response http_code body
  response=$(curl -s -w "\n%{http_code}" -X POST \
    "https://queue.fal.run/$endpoint" \
    -H "Authorization: Key $FAL_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "error: FAL queue submit failed (HTTP $http_code): $body" >&2
    return 1
  fi

  echo "$body" | jq -r '.request_id'
}

fal_queue_poll() {
  local endpoint="$1"
  local request_id="$2"
  local timeout_sec="${3:-600}"  # default 10 min
  local poll_interval="${4:-15}" # default 15s

  local elapsed=0
  while (( elapsed < timeout_sec )); do
    local status_json
    status_json=$(curl -s -X GET \
      "https://queue.fal.run/$endpoint/requests/$request_id/status?logs=1" \
      -H "Authorization: Key $FAL_KEY")

    local status
    status=$(echo "$status_json" | jq -r '.status')

    case "$status" in
      COMPLETED)
        echo "COMPLETED"
        return 0
        ;;
      FAILED)
        local error_msg
        error_msg=$(echo "$status_json" | jq -r '.error // "unknown error"')
        echo "FAILED: $error_msg" >&2
        return 1
        ;;
      IN_QUEUE|IN_PROGRESS)
        echo "  [$status] elapsed ${elapsed}s..." >&2
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
        ;;
      *)
        echo "  [unknown status: $status] elapsed ${elapsed}s..." >&2
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
        ;;
    esac
  done

  echo "error: timed out after ${timeout_sec}s" >&2
  return 1
}

fal_queue_result() {
  local endpoint="$1"
  local request_id="$2"

  local response http_code body
  response=$(curl -s -w "\n%{http_code}" -X GET \
    "https://queue.fal.run/$endpoint/requests/$request_id" \
    -H "Authorization: Key $FAL_KEY")
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "error: FAL result fetch failed (HTTP $http_code): $body" >&2
    return 1
  fi
  echo "$body"
}

fal_sync_call() {
  local endpoint="$1"
  local payload="$2"

  local response http_code body
  response=$(curl -s -w "\n%{http_code}" -X POST \
    "https://fal.run/$endpoint" \
    -H "Authorization: Key $FAL_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "error: FAL sync call failed (HTTP $http_code): $body" >&2
    return 1
  fi
  echo "$body"
}

fal_download() {
  local url="$1"
  local output="$2"
  local dir
  dir=$(dirname "$output")
  mkdir -p "$dir"

  local http_code
  http_code=$(curl -s -w "%{http_code}" -L -o "$output" "$url")
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "error: download failed (HTTP $http_code): $url" >&2
    rm -f "$output"
    return 1
  fi
  [[ -s "$output" ]] || { echo "error: downloaded file is empty: $output" >&2; rm -f "$output"; return 1; }
}
