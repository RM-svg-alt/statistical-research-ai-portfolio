# CHD Family Copilot

A research prototype of a multi-agent conversational assistant for families of children with congenital heart disease. The design emphasis is **safety and governance**: deterministic triage, evidence grounding, verification of claims against retrieved sources, and an audit record for every response.

> Research prototype. Not a medical device. It does not diagnose, prescribe, give sports clearance, or decide on surgery.

## Architecture

```
question
  ├─ local intent check ─────────────── greeting/thanks/help → reply with no LLM call
  ├─ context agent (rules + 1 LLM call) → age, diagnosis, activity, topics; longitudinal memory
  ├─ safety agent (rules, no LLM) ───── EMERGENCY / URGENT / ROUTINE + human-review flag
  ├─ missing-information detector ──── which facts the care team would need
  ├─ evidence: PubMed (cached) + curated guideline file
  ├─ router → up to 2 specialist agents (education, exercise, nutrition, surgery, QoL, caregiver)
  ├─ synthesis agent → one family-facing answer
  ├─ verifier agent → unsupported claims checked against retrieved evidence
  └─ governance record → safety level, sources used, verification status, agents run
```

## Design decisions

- **Safety triage is rule-based, not LLM-based.** Emergency symptoms are detected by deterministic rules, so behavior is predictable and auditable.
- **Deterministic extraction anchors the LLM.** High-confidence facts (age, diagnosis) extracted by rules override model output, and earlier context is never overwritten by "unknown."
- **Cost control.** Small-talk turns skip the LLM entirely. Specialist calls are capped. The verifier runs only for non-routine or multi-domain questions in "smart" mode.
- **Grounding.** The synthesis agent may cite a guideline only if one was retrieved, and the verifier flags claims that are not supported by the supplied material.

## Evaluation plan

- Triage sensitivity and specificity against clinician-labeled vignettes.
- Rate of unsupported claims (verifier versus expert review).
- Readability of answers.
- Agreement of answers with expert consensus.

## Setup

```bash
pip install -r requirements.txt
export OPENAI_API_KEY=...        # any LiteLLM-supported model via CHD_COPILOT_MODEL
export NCBI_EMAIL=you@example.org
```

Optional data files: `guidelines.json` (curated guideline summaries) and `providers_enriched.json` (public provider profiles).
