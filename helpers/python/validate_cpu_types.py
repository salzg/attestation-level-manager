#!/usr/bin/env python3
"""
Validates cpu-types.json against a list of legal CPU type strings

cpu-types.json (user input) is expected to be a non-empty JSON array. Each entry may specify the vCPU in one of three ways:

1) As CPU type string (LEGALITY CHECKED)
    Example:
        "EPYC-Milan"

    This is validated against legal-cpu-types.json

2) As a family/model/stepping triple (PASSTHROUGH)
    Example:
        {"family": 25, "model": 1, "stepping": 2}

    No legality check. They are passed through to sev-snp-measure via:
        --vcpu-family=<n> --vcpu-model=<n> --vcpu-stepping=<n>

3) As a vCPU signature (PASSTHROUGH)
    Example:
        "0x0a201009"
    or:
        {"vcpu_sig": "0x0a201009"}

    No legality check. They are passed through to sev-snp-measure via:
        --vcpu-sig=<hex>

Exit codes:
    0   valid
    2   invalid schema / parse error / illegal cpu type string
"""

import argparse
import json
import sys
import re
from typing import Any, Dict, List, NoReturn

HEX_RE = re.compile(r"^0x[0-9a-fA-F]+$")

def die(msg: str) -> NoReturn:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(2)

def load_json(path: str) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        die(f"Failed to read JSON '{path}': {e}")

def load_legal_cpu_types(path: str) -> List[str]:
    data = load_json(path)
    if not isinstance(data, list) or not data:
        die(f"legal-cpu-types.json must be a non-empty JSON list of strings: {path}")
    bad = [v for v in data if not isinstance(v, str) or not v.strip()]
    if bad:
        die(f"legal-cpu-types.json contains invalid entries (expect non-empty strings): {path}")
    out = []
    seen = set()
    for v in data:
        v = v.strip()
        if v in seen:
            continue
        seen.add(v)
        out.append(v)
    return out

def normalize_cpu_spec(entry: Any) -> Dict[str, Any]:
    """
    Return a normalized dict describing the cpu spec.

    One of:
      {"kind": "type", "type": <str>}
      {"kind": "sig", "sig": <hex str>}
      {"kind": "fms", "family": <int>, "model": <int>, "stepping": <int>}
    """
    # entry is either actual type string or straight up hex sig
    if isinstance(entry, str):
        s = entry.strip()
        if not s:
            die("cpu-types.json contains an empty string entry")
        if HEX_RE.match(s):
            return {"kind": "sig", "sig": s.lower()}
        return {"kind": "type", "type": s}

    # entry is the family, model, stepping triple OR sig encapsulated
    if isinstance(entry, dict):
        # signature form
        if "vcpu_sig" in entry or "sig" in entry:
            val = entry.get("vcpu_sig", entry.get("sig"))
            if isinstance(val, int):
                if val < 0:
                    die("vcpu_sig integer must be non-negative")
                return {"kind": "sig", "sig": hex(val).lower()}
            if isinstance(val, str) and HEX_RE.match(val.strip()):
                return {"kind": "sig", "sig": val.strip().lower()}
            die("vcpu_sig must be a hex string like 0x8b10 (or non-negative int)")

        # family/model/stepping form
        keys = ("family", "model", "stepping")
        if all(k in entry for k in keys):
            fam = entry.get("family")
            mod = entry.get("model")
            stp = entry.get("stepping")
            for k, v in (("family", fam), ("model", mod), ("stepping", stp)):
                if not isinstance(v, int):
                    die(f"{k} must be an int")
                if v < 0:
                    die(f"{k} must be non-negative")
            return {"kind": "fms", "family": fam, "model": mod, "stepping": stp}

        die("cpu-types.json dict entries must be either {family,model,stepping} or {vcpu_sig}/ {sig}")

    die("cpu-types.json entries must be strings or objects")

def spec_id(spec: Dict[str, Any]) -> str:
    # stable identifier used for uniqueness checks
    if spec["kind"] == "type":
        return f"type:{spec['type']}"
    if spec["kind"] == "sig":
        return f"sig:{spec['sig']}"
    if spec["kind"] == "fms":
        return f"fms:{spec['family']}:{spec['model']}:{spec['stepping']}"
    return "unknown"


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Validate cpu-types.json against legal-cpu-types.json")
    p.add_argument("--cpu-types", required=True, help="Path to cpu-types.json (user input)")
    p.add_argument("--legal-cpu-types", required=True, help="Path to legal-cpu-types.json (allowlist for string cpu types)")
    return p

def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)

    cpu_types = load_json(args.cpu_types)
    if not isinstance(cpu_types, list) or not cpu_types:
        die(f"cpu-types.json must be a non-empty JSON list: {args.cpu_types}")

    legal = set(load_legal_cpu_types(args.legal_cpu_types))

    seen = set()
    for entry in cpu_types:
        spec = normalize_cpu_spec(entry)
        sid = spec_id(spec)
        if sid in seen:
            die(f"cpu-types.json contains duplicate cpu specs (not allowed): {sid}")
        seen.add(sid)

        # legality check only for string cpu types
        if spec["kind"] == "type":
            if spec["type"] not in legal:
                die(f"Illegal cpu type string in cpu-types.json: '{spec['type']}' (not present in legal-cpu-types.json)")

    return

if __name__ == "__main__":
    main()
