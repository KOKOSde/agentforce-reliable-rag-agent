# Threat Model

## Assets
- Customer policy questions (`queryText`)
- Grounding records (`Policy__c`)
- Steering API response and safety decisions
- Correlation IDs for observability

## Key threats and controls

| Threat | Impact | Control in this repo |
| --- | --- | --- |
| Prompt injection attempts in user question | Ungrounded or unsafe answer | `PolicyRAGAction` only answers from retrieved policy records and enforces refusal when grounding is missing. |
| Steering API outage | Loss of governance check | Action returns answer with `STEERING_API_UNAVAILABLE` and reduced confidence, preserving traceability. |
| PII leakage in logs | Compliance breach | Logs include only redacted session ID suffix, citation count, flags, and correlation ID. |
| Over-privileged runtime user | Broader data exposure | `AgentforceRAGUser` grants read-only access to `Policy__c` and only required Apex class access. |
| Callout abuse or long waits | Latency and limit risk | Steering callout timeout is fixed at 4000 ms with governor limit guard before callout execution. |

## Residual risks
- Steering model quality depends on external endpoint behavior and should be versioned and monitored.
- `Policy__c` content quality drives factuality; governance process for policy curation is required.
