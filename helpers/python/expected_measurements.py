#!/usr/bin/env python3
"""Compute and save expected SEV-SNP VM launch measurements

This script is invoked by alman.sh to update expected-measurements.json

CPU specs:
    cpu-types.json is expected to be a non-empty JSON array. Each entry may
    specify the vCPU in one of three ways:

    1) CPU type string:
        "EPYC-Milan"
        leads to: sev-snp-measure: --vcpu-type "EPYC-Milan"

    2) family/model/stepping triple:
        {"family": 25, "model": 1, "stepping": 2}
        leads to: sev-snp-measure: --vcpu-family 25 --vcpu-model 1 --vcpu-stepping 2

    3) vCPU signature:
        "0x0a201009"  or  {"vcpu_sig": "0x0a201009"}
        leads to: sev-snp-measure: --vcpu-sig 0x0a201009

Args:
    --out-json         Path to expected-measurements.json
    --al               Attestation level (2|3|4)
    --vm-title         VM name
    --ovmf             Path to OVMF code file
    --kernel           Path to kernel (AL3/AL4); optional/ignored for AL2
    --initrd           Path to initrd (AL3/AL4); optional/ignored for AL2
    --append           Kernel cmdline (AL3/AL4); optional/ignored for AL2
    --vcpus            vCPU count
    --types-path       Path to cpu-types.json
    --measure-py       Path to sev-snp-measure.py

Output (stdout):
    Prints all computed measurements (one per line) as:
        <cpu_spec> <measurement_hex>
    If a measurement fails for a cpu_spec, prints:
        <cpu_spec> ERROR <message>
"""

import json
import os
import argparse
import subprocess
import sys
import time
import tempfile
import re
from typing import List, Dict, NoReturn, Tuple, Any
from validate_cpu_types import normalize_cpu_spec, spec_id

HEX_RE = re.compile(r"^0x[0-9a-fA-F]+$")

def die(msg: str, rc: int = 2) -> NoReturn:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(rc)

def load_json(path: str) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        die(f"Failed to read JSON '{path}': {e}")

def spec_id_human(spec: Dict[str, Any]) -> str:
    # human readable spec_id for printing
    if spec["kind"] == "type":
        return spec["type"]
    if spec["kind"] == "sig":
        return f"vcpu-sig={spec['sig']}"
    if spec["kind"] == "fms":
        return f"vcpu-family={spec['family']},vcpu-model={spec['model']},vcpu-stepping={spec['stepping']}"
    return "unknown"

def load_cpu_specs(path: str) -> List[Dict[str, Any]]:
    data = load_json(path)
    if not isinstance(data, list) or not data:
        die(f"CPU types JSON must be a non-empty list: {path}")

    specs: List[Dict[str, Any]] = []
    seen = set()
    for entry in data:
        spec = normalize_cpu_spec(entry)
        sid = spec_id(spec)
        if sid in seen:
            die(f"cpu-types.json contains duplicate cpu specs (not allowed): {sid}")
        seen.add(sid)
        specs.append(spec)
    return specs


def run_measure(measure_py: str, al: int, vcpus: int, spec: Dict[str, Any], ovmf: str, kernel: str, initrd: str, append: str) -> str:
    # sev-snp-measure per respective README:
    #   --mode snp --vcpus N --vcpu-type EPYC-Milan --vmm-type QEMU --ovmf <path> --kernel <path> --initrd <path> --append <string>
    # output explicitly as hex
    # vcpu-type could be replaced with either hex sig or the family, model, stepping trio
    cmd = [
        sys.executable,
        measure_py,
        "--mode",
        "snp",
        "--vmm-type",
        "QEMU",
        "--vcpus",
        str(vcpus),
        "--ovmf",
        ovmf,
        "--output-format",
        "hex",
    ]

    # vCPU spec selection (exactly one form)
    if spec["kind"] == "type":
        cmd += ["--vcpu-type", spec["type"]]
    elif spec["kind"] == "sig":
        cmd += ["--vcpu-sig", spec["sig"]]
    elif spec["kind"] == "fms":
        cmd += [
            "--vcpu-family",
            str(spec["family"]),
            "--vcpu-model",
            str(spec["model"]),
            "--vcpu-stepping",
            str(spec["stepping"]),
        ]
    else:
        die(f"Unknown cpu spec kind: {spec}")

    # AL2: ovmf-only measurement
    if al == 2:
        pass
    # AL3/AL4: include kernel, initrd, cmdline(append)
    elif al in (3, 4):
        if not kernel or not initrd:
            die("AL3/AL4 require kernel and initrd paths.")
        cmd += ["--kernel", kernel, "--initrd", initrd, "--append", append]
    else:
        die(f"Unsupported AL={al} (expected 2|3|4).")

    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        raise RuntimeError(
            f"sev-snp-measure.py failed for al={al} spec={spec} rc={p.returncode}\nSTDERR:\n{p.stderr}"
        )
    return p.stdout.strip()


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Compute and persist expected SEV-SNP launch measurements for a VM")
    p.add_argument("--out-json", required=True, help="Path to expected-measurements.json")
    p.add_argument("--al", required=True, type=int, choices=(2, 3, 4), help="Attestation level (2|3|4)")
    p.add_argument("--vm-title", required=True, help="VM name")
    p.add_argument("--ovmf", required=True, help="Path to OVMF code file")
    p.add_argument("--kernel", default="", help="Path to kernel (AL3/AL4); optional/ignored for AL2")
    p.add_argument("--initrd", default="", help="Path to initrd (AL3/AL4); optional/ignored for AL2")
    p.add_argument("--append", default="", help="Kernel cmdline (AL3/AL4); optional/ignored for AL2")
    p.add_argument("--vcpus", required=True, type=int, help="vCPU count")
    p.add_argument("--types-path", required=True, help='Path to cpu-types.json (JSON: {["EPYC-Milan", ...]})')
    p.add_argument("--measure-py", required=True, help="Path to sev-snp-measure.py")
    return p

def load_original(out_json: str) -> Dict:
    if not os.path.exists(out_json):
        return {}
    try:
        with open(out_json, "r", encoding="utf-8") as f:
            original = json.load(f)
    except Exception:
        return {}
    return original if isinstance(original, dict) else {}


def merge_vm_record_strict(existing: Dict, update: Dict) -> Dict:
    """
    Only the VM entry addressed by --vm-title is updated
    Unrelated custom fields under that VM entry are preserved
    Measurement sections are REPLACED, not merged:
        If you have removed one of the previously valid CPU types, that measurement will be gone!
    """
    if not isinstance(existing, dict):
        existing = {}

    merged = dict(existing)

    # fields to interact with
    owned_keys = (
        "timestamp_utc",
        "mode",
        "vmm_type",
        "al",
        "vcpus",
        "ovmf",
        "kernel",
        "initrd",
        "append",
        "cpu_types_config",
        "cpu_types",
        "all",
        "errors",
        "measurements"
    )
    for k in owned_keys:
        if k in update:
            merged[k] = update[k]

    return merged


def write_json(path: str, obj: Dict) -> None:
    out_dir = os.path.dirname(path) or "."
    os.makedirs(out_dir, exist_ok=True)

    fd = None
    tmp_path = None
    try:
        fd, tmp_path = tempfile.mkstemp(prefix=".expected-measurements.", suffix=".tmp", dir=out_dir)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2, sort_keys=True)
        fd = None
        os.replace(tmp_path, path)
        tmp_path = None
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except Exception:
                pass
        if tmp_path is not None:
            try:
                os.unlink(tmp_path)
            except Exception:
                pass


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)

    out_json = args.out_json
    al = args.al
    vm_title = args.vm_title
    ovmf = args.ovmf
    kernel = args.kernel
    initrd = args.initrd
    append = args.append
    vcpus = args.vcpus
    types_path = args.types_path
    measure_py = args.measure_py

    specs = load_cpu_specs(types_path)

    # Compute measurements
    measurements: Dict[str, Dict[str, str]] = {}
    errors: Dict[str, str] = {}
    # Printing log (cpu spec, measurement_hex, error)
    results_for_print: List[Tuple[str, str | None, str | None]] = []

    for spec in specs:
        label = spec_id_human(spec)
        try:
            m = run_measure(measure_py, al, vcpus, spec, ovmf, kernel, initrd, append)
            measurements[label] = {"cpu_spec": spec, "measurement_hex": m}
            results_for_print.append((label, m, None))
        except Exception as e:
            # for debugging
            err = str(e)
            errors[label] = err
            results_for_print.append((label, None, err))

    update_record = {
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mode": "snp",
        "vmm_type": "QEMU",
        "al": al,
        "vcpus": vcpus,
        "ovmf": ovmf,
        "kernel": kernel,
        "initrd": initrd,
        "append": append,
        "cpu_types_config": os.path.abspath(types_path),
        "cpu_types": specs,
        "measurements": measurements,
        "errors": errors,
    }

    # Read existing JSON if any
    original = load_original(out_json)

    existing_vm_entry = original.get(vm_title, {})
    original[vm_title] = merge_vm_record_strict(existing_vm_entry, update_record)

    write_json(out_json, original)

    # Print all measurements with their respective cpu type.
    for cpu_type, m, err in results_for_print:
        if m is not None:
            print(f"{cpu_type}\t{m}")
        else:
            # make errors single line
            msg = (err or "").replace("\n", "\\n")
            print(f"{cpu_type}\tERROR\t{msg}")

if __name__ == "__main__":
    main()
