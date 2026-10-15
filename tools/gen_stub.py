#!/usr/bin/env python3
"""
Generate minimal stub files in gen/ for test builds and CI validation
when the retail default.xbe is not provided.
"""

import os
import re
import shutil
import sys

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(here)
    gen_dir = os.environ.get("NFSU2_GEN_DIR", os.path.join(repo_root, "gen"))
    os.makedirs(gen_dir, exist_ok=True)

    types_src = os.path.join(repo_root, "xboxrecomp", "templates", "runtime", "recomp_types.h")
    types_dst = os.path.join(gen_dir, "recomp_types.h")
    if os.path.exists(types_src):
        shutil.copyfile(types_src, types_dst)
    elif not os.path.exists(types_dst):
        print(f"Error: {types_src} not found", file=sys.stderr)
        return 1

    # Scan src/ for all sub_ references and definitions
    src_dir = os.path.join(repo_root, "src")
    sym_pattern = re.compile(r'\b(sub_[0-9A-Fa-f]+(?:_gen)?)\b')
    # Only match non-inline void functions so inline ones get a weak external fallback
    def_pattern = re.compile(r'^void\s+(sub_[0-9A-Fa-f]+(?:_gen)?)\s*\(', re.M)

    referenced = set()
    defined = set()

    if os.path.exists(src_dir):
        for root, _, files in os.walk(src_dir):
            for f in files:
                if f.endswith(('.c', '.h', '.m', '.mm', '.cpp')):
                    path = os.path.join(root, f)
                    with open(path, "r", encoding="utf-8", errors="ignore") as fp:
                        content = fp.read()
                        for sym in sym_pattern.findall(content):
                            referenced.add(sym)
                        for dsym in def_pattern.findall(content):
                            defined.add(dsym)

    all_to_declare = set(referenced)
    for s in list(referenced):
        if s.endswith("_gen"):
            all_to_declare.add(s[:-4])
        else:
            all_to_declare.add(s + "_gen")

    funcs_h = os.path.join(gen_dir, "recomp_funcs.h")
    header_lines = [
        "#ifndef RECOMP_FUNCS_H",
        "#define RECOMP_FUNCS_H",
        "",
        '#include "recomp_types.h"',
        "",
        "#ifdef __cplusplus",
        'extern "C" {',
        "#endif",
        "",
        "void xbe_entry_point(void);",
        "int recomp_dispatch_init(void);",
        "size_t recomp_dispatch_flat_bytes(void);",
        "recomp_func_t recomp_lookup(uint32_t xbox_va);",
        "",
    ]

    for fn in sorted(all_to_declare):
        header_lines.append(f"void {fn}(void);")

    header_lines.extend([
        "",
        "#ifdef __cplusplus",
        "}",
        "#endif",
        "",
        "#endif /* RECOMP_FUNCS_H */",
        "",
    ])

    with open(funcs_h, "w", encoding="utf-8") as f:
        f.write("\n".join(header_lines))

    # All functions not strongly defined in src should have weak stubs in recomp_stub.c
    to_stub = sorted(all_to_declare - defined)

    stub_c = os.path.join(gen_dir, "recomp_stub.c")
    stub_lines = [
        "#include <stdio.h>",
        "#include <stdlib.h>",
        "#include <unistd.h>",
        '#include "recomp_funcs.h"',
        "",
        "int recomp_dispatch_init(void) {",
        '    fprintf(stderr, "[recomp-stub] Dispatch initialized (STUB build).\\n");',
        "    return 1;",
        "}",
        "",
        "size_t recomp_dispatch_flat_bytes(void) {",
        "    return 0;",
        "}",
        "",
        "recomp_func_t recomp_lookup(uint32_t xbox_va) {",
        "    (void)xbox_va;",
        "    return NULL;",
        "}",
        "",
        "void xbe_entry_point(void) {",
        '    fprintf(stderr, "[recomp-stub] Running NFSU2 iOS test stub.\\n");',
        '    fprintf(stderr, "[recomp-stub] Note: Provide retail default.xbe to generate real game code.\\n");',
        "    while (1) {",
        "        usleep(500000);",
        "    }",
        "}",
        "",
    ]

    for fn in to_stub:
        stub_lines.append(f"__attribute__((weak)) void {fn}(void) {{}}")

    stub_lines.append("")

    with open(stub_c, "w", encoding="utf-8") as f:
        f.write("\n".join(stub_lines))

    print(f"Successfully generated stub files in {gen_dir} ({len(all_to_declare)} declared, {len(to_stub)} stubbed)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
