from __future__ import annotations

import re

from kit import Refused


def analyze_log(text: str, mode: str, commit: str, expected_commit: str) -> dict:
    if mode not in ("diagnostic", "transaction", "unknown"):
        raise Refused("Unknown build mode")
    if len(text.encode("utf-8")) > 16 * 1024 * 1024:
        raise Refused("Log exceeds 16 MiB")
    reasons, evidence = [], []
    if commit != expected_commit:
        reasons.append("build-commit-unverified-or-mismatched")
    begin = list(re.finditer(r"TX:\s*BEGIN\b", text, re.I))
    failure = bool(re.search(
        r"transaction failed|asset validation failed|FWSEC.*(?:failed|timeout)|"
        r"PLM still locked|tu10x_unlock=false|unlock_persist=false|"
        r"\bPANIC\b|\bSTOP\b|CHAIN: failed|ABORTED|SECURITY_VIOLATION", text, re.I))
    error91 = bool(re.search(r"(?:mailbox0|mbox0|booter status)\s*[=:]?\s*0x0*91\b", text, re.I))
    if len(begin) > 1:
        reasons.append("multiple-transactions-in-one-log")
        failure = True
    if error91:
        reasons.append("booter-0x91")
        failure = True
    if failure:
        reasons.append("failure-or-unsafe-evidence-present")
    for line in text.splitlines():
        if re.search(r"TX: BEGIN|SELECTOR RESULT|TU10X PLM relock|HANDOFF-OUT|CHAIN:|transaction failed|mailbox0", line, re.I):
            evidence.append(line[:1400])
    handoffs = [line for line in text.splitlines() if "HANDOFF-OUT:" in line]
    last = handoffs[-1] if handoffs else ""
    final_values = re.search(r"tu10x:\s*plm=(0x[0-9a-f]+)\s+ss0=(0x[0-9a-f]+)\s+ss1=(0x[0-9a-f]+)", last, re.I)
    values = None
    if final_values:
        values = {k: int(v, 16) for k, v in zip(("plm", "ss0", "ss1"), final_values.groups())}
    selectors = bool(values and values["ss0"] == 0x88888888 and values["ss1"] == 8)
    final_good = selectors and bool(re.search(r"tu10x_unlock=true\b", last, re.I))
    known_relock = bool(values and values["plm"] == 0xffffffef)
    persist = bool(re.search(r"TU10X PLM relock:.*unlock_persist=true\b", text, re.I))
    chain = bool(re.search(r"CHAIN:.*(?:LoadImage|StartImage)", text, re.I))
    sample = "SAMPLE" in text and bool(re.search(r"(?:device|dev|10de|vendor)", text, re.I))
    if failure:
        verdict = "failure"
    elif reasons:
        verdict = "unverified-build"
    elif mode == "diagnostic" and begin:
        verdict = "mode-conflict"
        reasons.append("transaction-evidence-in-diagnostic-log")
    elif mode == "diagnostic" and sample and chain:
        verdict = "diagnostic-log-recorded"
    elif mode == "transaction" and len(begin) == 1 and final_good and known_relock and persist and chain:
        verdict = "candidate-unlock-needs-windows-and-numerical-validation"
    else:
        verdict = "incomplete-or-unknown"
        reasons.append("required-phase-evidence-missing")
    return {
        "verdict": verdict, "reasons": reasons, "build_mode_claim": mode,
        "commit_claim": commit, "transaction_count": len(begin),
        "final_turing_values": values, "plm_all_ones_required": False,
        "windows_health_verified": False, "numerical_validation_verified": False,
        "safe_to_retry": False, "safe_to_boot_inferred": False,
        "evidence": evidence[-80:],
        "note": "Log evidence is not independent proof of the build, cleanup, Windows health or numerical correctness.",
    }
