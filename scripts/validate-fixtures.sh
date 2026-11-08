#!/usr/bin/env bash
# Validates every committed fixture against the JSON Schemas. Runs from any directory.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

shopt -s nullglob
metadata=(fixtures/packages/captures/*/*/*/*/metadata.json)
markers=(fixtures/packages/captures/*/*/*/*/complete.json)
if [ "${#metadata[@]}" -eq 0 ] || [ "${#markers[@]}" -eq 0 ]; then
    echo "no fixtures found under fixtures/packages" >&2
    exit 1
fi

uvx check-jsonschema --schemafile schema/capture-metadata-v1.schema.json "${metadata[@]}"
uvx check-jsonschema --schemafile schema/complete-v1.schema.json "${markers[@]}"

enrichments=(fixtures/packages/enrichments/*/*/*/*/*/enrichment.json)
if [ "${#enrichments[@]}" -eq 0 ]; then
    echo "no enrichment fixtures found under fixtures/packages/enrichments" >&2
    exit 1
fi
uvx check-jsonschema --schemafile schema/enrichment-v1.schema.json "${enrichments[@]}"
