#!/usr/bin/env bash
set -euo pipefail

DATASET_FILE="${1:-scripts/eval/policy_qa_200.jsonl}"
COVERAGE_FILE="${2:-artifacts/apex-coverage-summary.json}"
OUTPUT_JSON="docs/benchmarks.json"
OUTPUT_MD="docs/benchmarks.md"

if [[ ! -f "${DATASET_FILE}" ]]; then
  echo "Dataset file not found: ${DATASET_FILE}" >&2
  exit 1
fi

mkdir -p docs artifacts

python3 - "${DATASET_FILE}" "${COVERAGE_FILE}" "${OUTPUT_JSON}" "${OUTPUT_MD}" <<'PY'
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

dataset_path, coverage_path, output_json, output_md = sys.argv[1:5]

rows = []
with open(dataset_path, "r", encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))

if not rows:
    raise SystemExit("Dataset is empty.")

unsupported_cases = 0
citation_scores = []
grounded_cases = 0

for row in rows:
    expected = set(row.get("expectedCitations", []))
    predicted = set(row.get("predictedCitations", []))
    unsupported_claims = int(row.get("unsupportedClaims", 0))

    if unsupported_claims > 0:
        unsupported_cases += 1
    if predicted:
        grounded_cases += 1

    if expected:
        citation_scores.append(len(expected.intersection(predicted)) / len(expected))
    else:
        citation_scores.append(1.0 if not predicted else 0.0)

metrics = {
    "generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "datasetFile": dataset_path,
    "datasetSha256": hashlib.sha256(open(dataset_path, "rb").read()).hexdigest(),
    "totalCases": len(rows),
    "citationCoveragePct": round(sum(citation_scores) / len(citation_scores) * 100, 2),
    "unsupportedClaimRatePct": round(unsupported_cases / len(rows) * 100, 2),
    "groundedAnswerRatePct": round(grounded_cases / len(rows) * 100, 2),
}

if os.path.exists(coverage_path):
    with open(coverage_path, "r", encoding="utf-8") as handle:
        coverage_payload = json.load(handle)
    if "apexCoveragePercent" in coverage_payload:
        metrics["apexCoveragePercent"] = round(float(coverage_payload["apexCoveragePercent"]), 2)

with open(output_json, "w", encoding="utf-8") as handle:
    json.dump(metrics, handle, indent=2)
    handle.write("\n")

rows_md = [
    ("Dataset cases", str(metrics["totalCases"])),
    ("Citation coverage", f'{metrics["citationCoveragePct"]}%'),
    ("Unsupported-claim rate", f'{metrics["unsupportedClaimRatePct"]}%'),
    ("Grounded-answer rate", f'{metrics["groundedAnswerRatePct"]}%'),
]
if "apexCoveragePercent" in metrics:
    rows_md.insert(0, ("Apex coverage", f'{metrics["apexCoveragePercent"]}%'))

with open(output_md, "w", encoding="utf-8") as handle:
    handle.write("# Benchmarks\n\n")
    handle.write("| Metric | Value |\n")
    handle.write("| --- | --- |\n")
    for metric, value in rows_md:
        handle.write(f"| {metric} | {value} |\n")
    handle.write(f"\nGenerated at: {metrics['generatedAt']}\n")
    handle.write(f"Dataset SHA-256: `{metrics['datasetSha256']}`\n")
PY

echo "Wrote ${OUTPUT_JSON} and ${OUTPUT_MD}"
