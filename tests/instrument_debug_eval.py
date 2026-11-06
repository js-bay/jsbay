#!/usr/bin/env python3
"""Count helper compilation attempts in an isolated contract source tree."""

import shutil
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
shutil.copytree(source, destination, dirs_exist_ok=True)
engine = destination / "quickjs.c"
text = engine.read_text()
needle = 'helper = JS_Eval(ctx, helper_source, sizeof(helper_source) - 1, "<debugger>", JS_EVAL_TYPE_GLOBAL);'
if text.count(needle) != 1:
    raise SystemExit("expected exactly one debugger helper compilation site")
text = text.replace(needle, 'puts("JSBAY_DEBUG_EVAL_HELPER_COMPILED"); fflush(stdout); ' + needle)
engine.write_text(text)
