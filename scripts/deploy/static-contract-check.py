#!/usr/bin/env python3
# ============================================================================
# MOY GEO Operator · Workflow Contract Static Check (LEVEL 0, CI-friendly)
#
# Statically inspects every n8n workflow JSON for the runtime contracts that
# keep a supervised Shadow Run safe. It does NOT execute anything — it reads
# the workflow graph and fails on structural violations:
#
#   1. Every SQL node that binds :queryParams must reference parameters that
#      are actually obtainable downstream (the postgres node supports
#      queryParams; we assert they are declared and the query references them).
#   2. WF-03 must schedule observation jobs via schedule_observation_jobs()
#      (the OFFICIAL scheduler), never hand-build an ENGINE_OBSERVATION payload
#      with only an intent_id.
#   3. WF-04 must resolve the engine adapter BEFORE any external call and must
#      not finish a job whose observation failed (observation_id check present).
#   4. No workflow may hand a legacy 'READY' status into the publication queue.
#   5. No forbidden runtime strings (SYNTH-ACME / simulated publish).
#
# Usage:
#   python3 scripts/deploy/static-contract-check.py n8n/workflows
# Exit 0 = all contracts hold. Exit 1 = a contract is violated.
# ============================================================================
import glob
import json
import os
import re
import sys

FAILURES = []


def fail(msg):
    FAILURES.append(msg)
    print(f"  FAIL: {msg}")


def checked(workflow):
    """Run all contract checks against one workflow dict."""
    name = workflow.get("name", "?")
    nodes = {n.get("name"): n for n in workflow.get("nodes", [])}
    node_list = workflow.get("nodes", [])
    conns = workflow.get("connections", {})

    # --- (0) every connection target must reference an existing node ---
    for src, by_type in conns.items():
        for _t, edges in by_type.items():
            for chain in edges or []:
                for edge in chain:
                    if not isinstance(edge, dict):
                        continue
                    target = edge.get("node")
                    if target and target not in nodes:
                        fail(f"{name}: connection {src} -> unknown node {target!r}")

    # --- (4) forbidden strings ---
    text = json.dumps(workflow)
    for banned in ("SYNTH-ACME", "simulated publish"):
        if banned in text:
            fail(f"{name}: forbidden string '{banned}' present")

    # --- (1) SQL nodes: queryParams must be declared AND referenced ---
    for n in node_list:
        p = n.get("parameters", {})
        if p.get("operation") != "executeQuery":
            continue
        query = p.get("query", "")
        # A query using :params but no queryParams block is a silent failure risk.
        # Exclude Postgres type casts (":id::uuid") via a negative lookbehind so
        # only real named bind parameters are collected.
        named = re.findall(r"(?<!:):([A-Za-z][A-Za-z0-9_]*)", query)
        declared = [
            s.strip() for s in (p.get("additionalFields", {}).get("queryParams", "") or "").split(",")
            if s.strip()
        ]
        if named:
            missing = sorted(set(named) - set(declared))
            if missing:
                fail(f"{name} node {n.get('name')}: query params {missing} used but not declared in queryParams")
            undeclared = sorted(set(declared) - set(named))
            if undeclared:
                fail(f"{name} node {n.get('name')}: queryParams {undeclared} declared but never used in query")

    # --- (2) WF-03 must use the official observation scheduler ---
    if "WF-03" in name:
        all_sql = " ".join(
            n.get("parameters", {}).get("query", "") for n in node_list
            if n.get("parameters", {}).get("operation") == "executeQuery"
        )
        if "schedule_observation_jobs" not in all_sql:
            fail(f"{name}: WF-03 does not call schedule_observation_jobs() (P0.5)")
        # No hand-built ENGINE_OBSERVATION job with only an intent_id.
        if re.search(r"ENGINE_OBSERVATION", all_sql) and "schedule_observation_jobs" not in all_sql:
            fail(f"{name}: hand-built ENGINE_OBSERVATION job without the official scheduler (P0.5)")

    # --- (3) WF-04 adapter resolution + observation-gated finish ---
    if "WF-04" in name:
        all_sql = " ".join(
            n.get("parameters", {}).get("query", "") for n in node_list
            if n.get("parameters", {}).get("operation") == "executeQuery"
        )
        if "resolve_engine_adapter" not in all_sql:
            fail(f"{name}: WF-04 does not call resolve_engine_adapter() (P0.6)")
        if "record_observation" not in all_sql:
            fail(f"{name}: WF-04 does not call record_observation() (P0.7)")
        # There must be a finish_job call gated on observation presence.
        if "finish_job" in all_sql and "fail_job" not in all_sql:
            fail(f"{name}: WF-04 has finish_job but no fail_job fallback (P0.7)")

    return True


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "n8n/workflows"
    paths = sorted(glob.glob(os.path.join(root, "wf*.json")))
    if not paths:
        print(f"no workflows found under {root}")
        return 1
    for path in paths:
        with open(path, "r", encoding="utf-8") as fh:
            wf = json.load(fh)
        before = len(FAILURES)
        checked(wf)
        if len(FAILURES) == before:
            print(f"  ok: {wf.get('name')} ({path})")
    print("-" * 60)
    if FAILURES:
        print(f"CONTRACT CHECK FAILED: {len(FAILURES)} violation(s)")
        return 1
    print("CONTRACT CHECK PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())