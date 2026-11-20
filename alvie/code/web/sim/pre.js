// What the testbench prints goes to the lines of the current run (see post.js), not to the console
Module['print'] = function (line) { if (Module.alvieLines) Module.alvieLines.push(line); };
Module['printErr'] = function (line) { if (Module.alvieLines) Module.alvieLines.push(line); };
