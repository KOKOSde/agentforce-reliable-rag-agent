<svg width="1080" height="190" viewBox="0 0 1080 190" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Agentforce reliable RAG architecture">
  <style>
    .box { fill:#f8fbff; stroke:#1b3a57; stroke-width:2; rx:12; }
    .text { font: 14px sans-serif; fill:#102a43; }
    .arrow { stroke:#334e68; stroke-width:2; marker-end:url(#m); }
  </style>
  <defs>
    <marker id="m" markerWidth="10" markerHeight="10" refX="8" refY="3" orient="auto">
      <path d="M0,0 L0,6 L9,3 z" fill="#334e68" />
    </marker>
  </defs>
  <rect class="box" x="20" y="52" width="150" height="56"/>
  <text class="text" x="40" y="86">Service Rep</text>
  <rect class="box" x="220" y="52" width="150" height="56"/>
  <text class="text" x="255" y="86">Agentforce</text>
  <rect class="box" x="420" y="52" width="170" height="56"/>
  <text class="text" x="445" y="86">Prompt Builder</text>
  <rect class="box" x="640" y="52" width="170" height="56"/>
  <text class="text" x="675" y="86">Apex Action</text>
  <rect class="box" x="860" y="18" width="190" height="56"/>
  <text class="text" x="900" y="52">Retriever</text>
  <rect class="box" x="860" y="104" width="190" height="56"/>
  <text class="text" x="896" y="138">Steering API</text>
  <line class="arrow" x1="170" y1="80" x2="220" y2="80"/>
  <line class="arrow" x1="370" y1="80" x2="420" y2="80"/>
  <line class="arrow" x1="590" y1="80" x2="640" y2="80"/>
  <line class="arrow" x1="810" y1="80" x2="860" y2="46"/>
  <line class="arrow" x1="810" y1="80" x2="860" y2="132"/>
  <line class="arrow" x1="1050" y1="80" x2="1000" y2="80"/>
  <text class="text" x="700" y="176">Answer + citations + confidence + safety flags + correlation ID</text>
</svg>

# agentforce-reliable-rag-agent

Service teams lose time and trust when policy answers are fast but wrong. This repository delivers a scratch-org-ready Agentforce pattern that forces grounded citations, blocks unsafe responses when policy grounding is weak, and emits traceable response metadata for audit and operations.

## Measured Results

Generated from `scripts/run-tests.sh` and `scripts/eval/run_eval.sh` into `docs/benchmarks.json`:

- Apex coverage (CI gate): **90.0%**
- Citation coverage: **94.0%**
- Unsupported-claim rate: **4.5%**
- Grounded-answer rate: **94.0%**

## How it works

- Prompt Builder template (`PolicyAnswer`) defines tone, refusal behavior, and citation contract.
- `PolicyRAGAction` retrieves matching `Policy__c` records and builds structured citations.
- `PolicyRAGAction` calls `callout:SteeringAPI/v1/steer` through Named Credential before returning.
- Response payload always includes `answer`, `citations[]`, `confidenceScore`, `safetyFlags[]`, and `correlationId`.

## Deploy

```bash
# Authenticate your Dev Hub once per machine
sf org login sfdx-url --sfdx-url-file ./SFDX_AUTH_URL.txt --alias devhub --set-default-dev-hub

# Create, deploy, assign perm set, and seed sample policy records
bash scripts/setup-scratch-org.sh agentforce-rag

# Run Apex tests with coverage gating (fails below 85%)
bash scripts/run-tests.sh agentforce-rag

# Run offline eval and regenerate docs/benchmarks.json + docs/benchmarks.md
bash scripts/eval/run_eval.sh

# Delete scratch org
bash scripts/teardown-scratch-org.sh agentforce-rag
```

## Security model

- **Named Credentials**: `SteeringAPI` isolates the Steering endpoint; use org-managed secret strategy when moving beyond `NoAuthentication`.
- **Least privilege**: `AgentforceRAGUser` grants read-only access to `Policy__c` and access only to `PolicyRAGAction`.
- **PII handling**: response logging stores redacted session suffix, flags, and `correlationId`; no raw question text is logged.
- **Logging boundaries**: outbound payload contains query + citations for steering, while platform logs keep operational metadata only.

## Documentation

- Architecture: `docs/architecture.md`
- Threat model: `docs/threat-model.md`
- Benchmarks: `docs/benchmarks.md`
- Developer handoff checklist: `docs/handoff-checklist.md`
