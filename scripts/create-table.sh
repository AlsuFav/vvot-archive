#!/usr/bin/env bash
set -euo pipefail

: "${YC_TOKEN:?Set YC_TOKEN to your Yandex Cloud IAM token}"
: "${DOCAPI_ENDPOINT:?Document API endpoint is required}"

table='{"TableName":"archives"}'
schema='{"TableName":"archives","AttributeDefinitions":[{"AttributeName":"key","AttributeType":"S"}],"KeySchema":[{"AttributeName":"key","KeyType":"HASH"}],"BillingMode":"PAY_PER_REQUEST"}'
response=$(mktemp)
trap 'rm -f "$response"' EXIT

docapi() {
  curl --silent --show-error --max-time 15 --output "$response" --write-out '%{http_code}' \
    --header "Authorization: Bearer ${YC_TOKEN}" \
    --header "X-Amz-Target: DynamoDB_20120810.$1" \
    --header 'Content-Type: application/x-amz-json-1.0' \
    --data "$2" "$DOCAPI_ENDPOINT"
}

# Повторный apply может обнаружить уже созданную таблицу.
for attempt in {1..15}; do
  if status=$(docapi DescribeTable "$table"); then
    if [[ "$status" == 200 ]] && jq -e '.Table.TableStatus == "ACTIVE"' "$response" >/dev/null; then
      jq -e '.Table.KeySchema == [{"AttributeName":"key","KeyType":"HASH"}]
        and any(.Table.AttributeDefinitions[]; .AttributeName == "key" and .AttributeType == "S")' \
        "$response" >/dev/null
      printf 'Document table archives is ready.\n'
      exit 0
    fi
    if [[ "$status" == 400 ]] && jq -e '.__type | endswith("ResourceNotFoundException")' "$response" >/dev/null 2>&1; then
      status=$(docapi CreateTable "$schema") || status=000
      if [[ "$status" != 200 && "$status" != 000 && "$status" != 429 && "$status" != 5* ]] \
        && ! jq -e '.__type | endswith("ResourceInUseException")' "$response" >/dev/null 2>&1; then
        printf 'CreateTable failed (HTTP %s).\n' "$status" >&2
        cat "$response" >&2
        exit 1
      fi
    fi
    if [[ "$status" == 401 || "$status" == 403 ]]; then
      printf 'Document API authorization failed (HTTP %s).\n' "$status" >&2
      exit 1
    fi
  fi
  sleep 4
done

printf 'Document table archives did not become active. Check YDB and YC_TOKEN.\n' >&2
cat "$response" >&2
exit 1
