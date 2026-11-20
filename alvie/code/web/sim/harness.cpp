// The testbench of ALVIE (bench/verilog/tb_openMSP430.v with src/generic.v) as a WebAssembly module that runs many
// steps: alvie_sim_run runs the program in pmem.mem once, to the $finish of the testbench, and writes its trace in
// tb_openMSP430.vcd (in the file system of Emscripten, see post.js), as the simv of ALVIE does. Each run has its own
// VerilatedContext, so that a $finish ends only that run.
#include "verilated.h"
#include "Vtb_openMSP430.h"
#include <cstdio>
#include <emscripten.h>

extern "C" EMSCRIPTEN_KEEPALIVE int alvie_sim_run() {
    {
        VerilatedContext ctx;
        ctx.traceEverOn(true);
        Vtb_openMSP430 top{&ctx};
        while (!ctx.gotFinish()) {
            top.eval();
            if (!top.eventsPending()) break;
            ctx.time(top.nextTimeSlot());
        }
        top.final();
    }  // the model and its trace file are closed here
    std::fflush(stdout);
    return 0;
}

int main() { return 0; }
