"""Tiny in Python that misbehaves as its argument says, to test how Core handles external plugins (test/rpc.sh)."""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tiny  # noqa: E402  (a copy of plugins/tiny-py/tiny.py, next to this file)
from alvie_plugin import PluginError, serve, log  # noqa: E402

MODE = sys.argv[1]


class Bad(tiny.Tiny):
    steps = 0

    def step(self, step):
        Bad.steps += 1
        if Bad.steps == 3:
            if MODE == "crash":
                log("about to crash: step", step)
                sys.exit(3)
            if MODE == "hang":
                log("hanging")
                time.sleep(600)
            if MODE == "noise":
                print("debugging output on stdout", flush=True)
            if MODE == "error":
                raise PluginError("the simulator rejected the program")
            if MODE == "bug":
                return [{"Exit": {}}][5]
        return super().step(step)


if MODE == "version":
    serve("tiny-py", "1999.01", Bad)
elif MODE == "nocap":
    Bad.capabilities = ("restore",)
    serve("tiny-py", "2026.10", Bad)
else:
    serve("tiny-py", "2026.10", Bad)
