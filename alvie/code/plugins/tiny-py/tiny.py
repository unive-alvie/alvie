"""Tiny, the reference platform of ALVIE/Core, as an external plugin in Python (see lib/core/tiny/tiny.ml).

The processor runs the attacker's code or the enclave's. The attacker arms the timer (timer n) and calls the
enclave, whose four registers start at 0. Each instruction of the enclave takes one or two cycles; when the timer
expires during one, it completes and the interrupt is handled, with a latency of the cycles it still ran. reti
resumes the enclave (once); ret returns to the attacker, which sees the cycles since the call or the last resume.
"""

import os
import sys

try:
    import alvie_plugin  # noqa: F401  (on PYTHONPATH)
except ImportError:  # the SDK of this checkout
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "sdk", "python"))

from alvie_plugin import Backend, PluginError, serve, get, tag  # noqa: E402
import tiny_types as obs  # noqa: E402

REGISTERS = 4


class Tiny(Backend):
    capabilities = ("restore", "clone")

    def __init__(self, config, variant):
        super().__init__(config, variant)
        mitigation = config.get("mitigation", "none")
        if mitigation not in ("none", "constant-time"):
            raise PluginError(f"Tiny: unknown mitigation {mitigation!r} (expected none or constant-time)")
        if variant not in (None, "no-interrupts"):
            raise PluginError(f"Tiny: unknown variant {variant!r} (expected no-interrupts)")
        self.constant_time = mitigation == "constant-time"
        self.interrupts = variant is None
        self.pre()

    def pre(self):
        self.enclave = None  # its registers, while it runs
        self.timer = None  # cycles of the enclave until it expires
        self.interrupted = None  # the registers of the enclave that the timer interrupted
        self.cycles = 0

    def clone(self):
        c = Tiny.__new__(Tiny)
        c.__dict__.update(self.__dict__)
        c.enclave = None if self.enclave is None else list(self.enclave)
        c.interrupted = None if self.interrupted is None else list(self.interrupted)
        return c

    def attacker(self, atom):
        t = tag(atom)
        if t == "nop":
            return obs.Ok()
        if t == "timer":
            if self.interrupts:
                self.timer = get(atom, "cycles")
            return obs.Ok()
        if t == "call":
            self.enclave, self.interrupted, self.cycles = [0] * REGISTERS, None, 0
            return obs.Enter()
        if t == "reti":
            if self.interrupted is None:
                return obs.Ok()
            self.enclave, self.interrupted, self.cycles = self.interrupted, None, 0
            return obs.Resume()
        if t == "halt":
            return obs.Done()
        return obs.Illegal()

    def run(self, cycles):
        self.cycles += cycles
        if self.timer is not None and self.timer <= cycles:
            left, self.timer = self.timer, None
            self.interrupted, self.enclave = self.enclave, None
            return obs.Irq(latency=cycles - left)
        if self.timer is not None:
            self.timer -= cycles
        return obs.Run()

    def in_enclave(self, atom):
        regs = self.enclave
        t = tag(atom)

        def one_or_two(zero):
            r = get(atom, "r", "i")
            return 2 if self.constant_time or ((regs[r] == 0) == zero) else 1

        if t == "nop":
            return self.run(1)
        if t == "mov":
            regs[get(atom, "r", "i")] = get(atom, "v", "num")
            return self.run(1)
        if t == "bz":
            return self.run(one_or_two(True))
        if t == "pad":
            return self.run(one_or_two(False))
        if t == "ret":
            time = self.cycles + 1
            self.enclave, self.timer, self.cycles = None, None, 0
            return obs.Exit(time=time)
        return obs.Illegal()

    def step(self, step):
        cls = "enclave" if step.section == "enclave" else "attacker"
        if self.enclave is None and cls == "attacker":
            return [self.attacker(step.atom)]
        if self.enclave is not None and cls == "enclave":
            return [self.in_enclave(step.atom)]
        return [obs.Illegal()]


if __name__ == "__main__":
    serve("tiny-py", "2026.10", Tiny)
