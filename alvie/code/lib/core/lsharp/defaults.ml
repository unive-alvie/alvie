(*
  The defaults of the learner and of its oracles, in one place: the oracles (their make), alvie <plugin> learn and
  fixtures (Alvie_cli.Runner), and learn.exe use these values, so that every plugin and every command learns with
  the same settings unless it is told otherwise.

  - PAC: epsilon = delta = 0.01, the values of the experiments of the paper (learn_all.sh, results/, the attack
    catalogue).
  - Random walk: 500 steps for each equivalence query, a reset with probability 0.05 after each step (learn.exe of
    CSF'24, and the guide "Choosing Learner Settings").
  - W-method: the system may have 1 state more than the hypothesis.
  - The seed of the random choices: 0.

  The probability of an input outside the spec (--bad-probability) is not here: it belongs to the plugin (its codec,
  Runner.CODEC.default_bad_probability), e.g. 0.20 for Sancus and none for the plugins that learn on values.
*)

let oracle = "pac"
let pac_epsilon = 0.01
let pac_delta = 0.01
let random_walk_steps = 500
let random_walk_reset_probability = 0.05
let wmethod_extra_states = 1
let seed = 0
