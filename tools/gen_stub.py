#!/usr/bin/env python3
"""
Generate minimal stub files in gen/ for test builds and CI validation
when the retail default.xbe is not provided.
"""

import os
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

    funcs_h = os.path.join(gen_dir, "recomp_funcs.h")
    funcs_content = """#ifndef RECOMP_FUNCS_H
#define RECOMP_FUNCS_H

#include "recomp_types.h"

#ifdef __cplusplus
extern "C" {
#endif

void xbe_entry_point(void);
int recomp_dispatch_init(void);

void sub_0009A330_gen(void);
void sub_0009A250_gen(void);
void sub_002E8F20_gen(void);
void sub_002F1D80_gen(void);
void sub_002F22F0_gen(void);
void sub_00072F90_gen(void);
void sub_002618F0_gen(void);
void sub_002213EA_gen(void);
void sub_002A68EC_gen(void);
void sub_0004BC20_gen(void);
void sub_0004B260_gen(void);
void sub_001C6900_gen(void);
void sub_000113A0_gen(void);
void sub_001C3430_gen(void);
void sub_0004C6E0_gen(void);
void sub_001C65D0_gen(void);
void sub_002EEA80_gen(void);
void sub_0004B940_gen(void);
void sub_000A3CA0_gen(void);
void sub_0025ECB4_gen(void);
void sub_00129610_gen(void);
void sub_0032EB65_gen(void);
void sub_00012345(void);

#ifdef __cplusplus
}
#endif

#endif /* RECOMP_FUNCS_H */
"""
    with open(funcs_h, "w", encoding="utf-8") as f:
        f.write(funcs_content)

    stub_c = os.path.join(gen_dir, "recomp_stub.c")
    stub_content = """#include <stdio.h>
#include <unistd.h>
#include "recomp_funcs.h"

int recomp_dispatch_init(void) {
    fprintf(stderr, "[recomp-stub] Dispatch initialized (STUB build).\\n");
    return 1;
}

void xbe_entry_point(void) {
    fprintf(stderr, "[recomp-stub] Running NFSU2 iOS test stub.\\n");
    fprintf(stderr, "[recomp-stub] Note: Provide retail default.xbe to generate real game code.\\n");
    while (1) {
        usleep(500000);
    }
}

void sub_0009A330_gen(void) {}
void sub_0009A250_gen(void) {}
void sub_002E8F20_gen(void) {}
void sub_002F1D80_gen(void) {}
void sub_002F22F0_gen(void) {}
void sub_00072F90_gen(void) {}
void sub_002618F0_gen(void) {}
void sub_002213EA_gen(void) {}
void sub_002A68EC_gen(void) {}
void sub_0004BC20_gen(void) {}
void sub_0004B260_gen(void) {}
void sub_001C6900_gen(void) {}
void sub_000113A0_gen(void) {}
void sub_001C3430_gen(void) {}
void sub_0004C6E0_gen(void) {}
void sub_001C65D0_gen(void) {}
void sub_002EEA80_gen(void) {}
void sub_0004B940_gen(void) {}
void sub_000A3CA0_gen(void) {}
void sub_0025ECB4_gen(void) {}
void sub_00129610_gen(void) {}
void sub_0032EB65_gen(void) {}
void sub_00012345(void) {}
"""
    with open(stub_c, "w", encoding="utf-8") as f:
        f.write(stub_content)

    print(f"Successfully generated stub files in {gen_dir}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
