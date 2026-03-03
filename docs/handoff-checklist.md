# Developer Handoff Checklist

- Confirm Dev Hub auth secret is present in GitHub: `SF_DEVHUB_SFDX_URL`.
- Update the `SteeringAPI` Named Credential endpoint and authentication mode for production.
- Deploy to a fresh scratch org with `scripts/setup-scratch-org.sh`.
- Verify the `AgentforceRAGUser` permission set assignment for support users.
- Run `scripts/run-tests.sh` and confirm org-wide Apex coverage stays above 85%.
- Run `scripts/eval/run_eval.sh` and review `docs/benchmarks.json` + `docs/benchmarks.md`.
- Confirm `policyAssistant` LWC renders answer, citations, confidence, and safety flags.
- Review `docs/threat-model.md` with security and compliance owners.
- Validate logging pipeline stores `correlationId` and safety flags only.
- Complete production release checklist for Named Credentials and outbound allowlists.
