let incomplete_simulator_failure () =
  match Cli_diagnostics.classify_failure "Simulator: Stimulus did not complete!" with
  | Some (heading, message, status) ->
    Alcotest.(check string) "heading" "ALVIE incomplete" heading;
    Alcotest.(check string)
      "message"
      "the simulator did not finish. Inspect the run log and retry in a fresh namespace."
      message;
    Alcotest.(check int) "status" 3 status
  | None -> Alcotest.fail "The simulator noncompletion failure was not classified."

let () =
  Alcotest.run "ALVIE diagnostics"
    ["failure classification", [Alcotest.test_case "simulator noncompletion" `Quick incomplete_simulator_failure]]
