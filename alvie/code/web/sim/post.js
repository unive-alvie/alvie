// run(mem): runs the program mem (the text, or the bytes, of a $readmemh file, as Msp430_asm.mem_file writes it) and
// returns { status, vcd }: status as ALVIE's scripts/simulate gives it (0 success, 1 the stimulus did not complete,
// 2 timeout, 3 another failure), vcd the bytes of the trace (a Uint8Array).
Module['run'] = function (mem) {
  FS.writeFile('/pmem.mem', mem);
  try { FS.unlink('/tb_openMSP430.vcd'); } catch (e) {}
  Module.alvieLines = [];
  Module._alvie_sim_run();
  const out = Module.alvieLines.join('\n');
  Module.alvieLines = null;
  let status = 0;
  if (out.includes('SIMULATION FAILED'))
    status = out.includes("the verilog stimulus didn't complete") ? 1 : out.includes('simulation Timeout') ? 2 : 3;
  let vcd = new Uint8Array(0);
  try { vcd = FS.readFile('/tb_openMSP430.vcd'); } catch (e) { status = 3; }
  return { status: status, vcd: vcd, output: out };
};
