#!/usr/bin/env bash
set -euo pipefail

api_url=${1:-$(terraform output -raw api_url)}
api_url=${api_url%/}
source_url=${DEMO_SOURCE_URL:-https://www.rfc-editor.org/rfc/rfc9562.txt}
name="demo-$(date +%s)-$$.txt"
missing='00000000-0000-7000-8000-000000000000.zip'
key_regex='^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.zip$'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

request() {
  local expected=$1 route=$2 code
  shift 2
  code=$(curl -sS --max-time 20 -D "$tmp/headers" -o "$tmp/body" -w '%{http_code}' "$@" "$api_url$route")
  printf '%s → HTTP %s\n' "$route" "$code"
  if [[ "$code" != "$expected" ]]; then
    printf 'Expected HTTP %s. Response body:\n' "$expected" >&2
    head -c 2048 "$tmp/body" >&2
    return 1
  fi
}

json_header='Content-Type: application/json'
request 400 /tasks -H "$json_header" --data '{"name":"no-url.txt"}'
request 400 /tasks -H "$json_header" --data '{"name":"wrong-url.txt","url":"not-a-url"}'
request 400 /tasks -H "$json_header" --data '{'
request 404 "/archives/$missing"
request 404 "/download/$missing"

curl -fsSL --max-time 30 "$source_url" -o "$tmp/source"
task=$(jq -nc --arg name "$name" --arg url "$source_url" '{name:$name,url:$url}')
request 202 /tasks -H "$json_header" --data "$task"

printf 'Waiting for archive %s\n' "$name"
key=''
for ((attempt=1; attempt<=75; attempt++)); do
  curl -fsS --max-time 20 "$api_url/archives" -o "$tmp/list"
  key=$(jq -r --arg name "$name" --arg url "$source_url" \
    '[.[] | select(.name == $name and .url == $url) | .key] | first // empty' "$tmp/list")
  [[ -n "$key" ]] && break
  sleep 4
done
if [[ ! "$key" =~ $key_regex ]]; then
  printf 'No archive with a valid UUIDv7 key appeared. Check the trigger and function logs.\n' >&2
  exit 1
fi
printf '/archives → HTTP 200\n'
jq --arg key "$key" '.[] | select(.key == $key)' "$tmp/list"

request 200 "/archives/$key"
jq -e --arg name "$name" --arg url "$source_url" --arg key "$key" \
  '. == {name:$name,url:$url,key:$key}' "$tmp/body"

request 200 "/download/$key"
grep -iE '^content-type:[[:space:]]*application/zip([;[:space:]]|$)' "$tmp/headers"
mv "$tmp/body" "$tmp/archive.zip"
unzip -t "$tmp/archive.zip"
[[ $(unzip -Z -1 "$tmp/archive.zip") == "$name" ]]
unzip -p "$tmp/archive.zip" "$name" > "$tmp/extracted"
cmp "$tmp/source" "$tmp/extracted"
printf 'PASS: API, UUIDv7, ZIP entry name and original file bytes.\n'
