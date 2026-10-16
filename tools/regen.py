#!/usr/bin/env python3
"""
Python script to run the static recompilation pipeline for NFSU2:
disasm -> func_id -> abi_analysis -> recomp
"""

import os
import sys
import subprocess

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(here)
    tk_dir = os.path.join(repo_root, "xboxrecomp")
    
    default_xbe = os.environ.get("NFSU2_XBE")
    if not default_xbe or not os.path.exists(default_xbe):
        candidates = [
            r"C:\Users\msuda\Downloads\isoextract\NFSU2\default.xbe",
            os.path.join(repo_root, "game", "default.xbe"),
        ]
        for c in candidates:
            if os.path.exists(c):
                default_xbe = c
                break
                
    if not default_xbe or not os.path.exists(default_xbe):
        print("Error: default.xbe not found. Set NFSU2_XBE environment variable.", file=sys.stderr)
        return 1

    gen_dir = os.environ.get("NFSU2_GEN_DIR", os.path.join(repo_root, "gen"))
    seed_json = os.path.join(repo_root, "config", "seed_functions.json")
    manual_c = os.path.join(repo_root, "src", "recomp_manual.c")
    
    out_dir = os.path.join(tk_dir, "tools", "disasm", "output")
    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(gen_dir, exist_ok=True)
    
    analysis_json = os.path.join(out_dir, "default_analysis.json")

    print(f"==> XBE: {default_xbe}")
    print(f"==> Gen dir: {gen_dir}")

    # 1. XBE Parser
    print("==> 1/5: Running tools.xbe_parser...")
    cmd1 = [sys.executable, "-m", "tools.xbe_parser", default_xbe, "--json", analysis_json, "--quiet"]
    subprocess.check_call(cmd1, cwd=tk_dir)

    # 2. Disasm
    print("==> 2/5: Running tools.disasm...")
    cmd2 = [sys.executable, "-m", "tools.disasm", default_xbe, "--seed-functions", seed_json, "--analysis-json", analysis_json]
    subprocess.check_call(cmd2, cwd=tk_dir)

    # 3. Func ID
    print("==> 3/5: Running tools.func_id...")
    cmd3 = [sys.executable, "-m", "tools.func_id", default_xbe]
    subprocess.check_call(cmd3, cwd=tk_dir)

    # 4. ABI Analysis
    print("==> 4/5: Running tools.abi_analysis...")
    cmd4 = [sys.executable, "-m", "tools.abi_analysis", default_xbe]
    subprocess.check_call(cmd4, cwd=tk_dir)

    # 5. Recomp
    print("==> 5/5: Running tools.recomp...")
    types_h = os.path.join(gen_dir, "recomp_types.h")
    if os.path.exists(types_h):
        os.remove(types_h)
    cmd5 = [
        sys.executable, "-m", "tools.recomp", default_xbe,
        "--game-name", "NFS Underground 2",
        "--all",
        "--split", "250",
        "--gen-dir", gen_dir,
        "--exclude-manual", manual_c,
        "--mmio-sections", "DSOUND,XPP"
    ]
    subprocess.check_call(cmd5, cwd=tk_dir)

    print(f"==> DONE! Recompiled game code successfully generated in: {gen_dir}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
