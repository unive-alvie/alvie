open Sancus.Output_internal

(* Toy example tests *)
let input_attacker_encl = "att: start_counting 256;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ubr"

let output_attacker_encl0 = [
  [
    (OTime { k = 7; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 10; mode = PM });
    (OJmpOut { k = 2; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 12; mode = UM })
  ]
]

let output_attacker_encl1 = [
  [
    (OJmpOut { k = 2; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 5; mode = UM })
  ]
]


(* B1 tests *)
let input_b1_encl_int = "
att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (add #1, &data_s; nop) (nop; add #1, &data_s);
att: timer_enable 1;
att: reti"

let input_b1_encl_noint = "
att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (add #1, &data_s; nop) (nop; add #1, &data_s);
enc: jmp #enc_e"

let output_b1_encl_noint = [
  [(OJmpOut { k = 3; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0x3; mode = UM })]
]

let output_b1_encl0_int_orig = [
  [
    (OTime { k = 14; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = UM });
    (OReti { k = 3; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = PM });
    (OTime_Handle (
      { k = 0; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x1; mode = PM },
      { k = 9; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x1; mode = UM }
      )
    )
  ]
]

let output_b1_encl1_int_orig = [
  [
    (OTime { k = 14; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = UM });
    (OReti { k = 2; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 1; mode = PM });
    (OTime_Handle (
      { k = 2; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 1; mode = PM },
      { k = 7; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = UM }
      )
    )
  ]
]

(* Notice that observables with "PM" are skipped by the equality, so they are just placeholders *)
let output_b1_encl_int_last = [
    [
      (OTime { k = 14; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = UM });
      (OReti { k = 4; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 1; mode = PM });
      (OTime_Handle (
        { k = 0; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 1; mode = PM },
        { k = 8; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 1; mode = UM }
        )
      )
    ]
]

(* B2 tests *)
let input_b2_encl_int = "att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (mov &enc_s, &enc_s; nop) (nop; mov &enc_s, &enc_s)"

let input_b2_encl_noint = "att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (mov &enc_s, &enc_s; nop) (nop; mov &enc_s, &enc_s);
enc: jmp #enc_e"

let output_b2_encl_noint = [
  [(OJmpOut { k = 3; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = UM })]
]

let output_b2_encl0_int_orig = [
  [OTime_Handle (
    { k = 9; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = PM },
    { k = 10; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x4; mode = UM })
  ]
]

let output_b2_encl1_int_orig = [
  [OTime_Handle (
    { k = 3; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = PM },
    { k = 8; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x2; mode = UM })
  ]
]

(* Notice that observables with "PM" are skipped by the equality, so they are just placeholders *)
let output_b2_encl_int_last = [
  [OTime_Handle (
      { k = 9; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = PM },
      { k = 3; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x3; mode = UM }
    )
  ]
]

(* B3 tests *)
let input_b3_encl_noint = "att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (add #1, &data_s; nop) (nop; add #1, &data_s);
enc: mov &data_s, r4;
enc: jmp #enc_e;
att: reti"

let input_b3_encl_int = "att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (add #1, &data_s; nop) (nop; add #1, &data_s);
att: reti;
enc: mov &data_s, r4;
enc: jmp #enc_e;
att: reti;
enc: mov &data_s, r4;
enc: jmp #enc_e"

let input_b3_encl_int_last = "att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (add #1, &data_s; nop) (nop; add #1, &data_s);
att: reti;
enc: mov &data_s, r4;
enc: jmp #enc_e;
att: reti"

let output_b3_encl_noint = [
  [(OTime { k = 19; gie = false; umem_val = 0; reg_val = 0x1; timerA_counter = 0x4; mode = UM })]
]

let output_b3_encl0_int_orig = [
  [(OJmpOut { k = 3; gie = true; umem_val = 0; reg_val = 0x1; timerA_counter = 0; mode = UM })]
]

let output_b3_encl1_int_orig = [
  [(OJmpOut { k = 3; gie = true; umem_val = 0; reg_val = 0x2; timerA_counter = 0; mode = UM })]
]

let output_b3_encl_int_last = [
  [(OTime { k = 19; gie = false; umem_val = 0; reg_val = 0x1; timerA_counter = 0; mode = UM })]
]

(* B4 tests *)
let input_b4_encl_noint = "att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (add #1, &data_s; nop) (nop; add #1, &data_s);
enc: mov &data_s, r4;
enc: jmp #enc_e"

let input_b4_encl_int = "
att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (add #1, &data_s; nop) (nop; add #1, &data_s);
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (add #1, &data_s; nop) (nop; add #1, &data_s);
enc: mov &data_s, r4;
enc: jmp #enc_e"

let input_b4_encl_int_last = "
att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (add #1, &data_s; nop) (nop; add #1, &data_s);
att: jin enc_s;
enc: cmp ?, r4"

let output_b4_encl_noint = [
  [(OJmpOut { k = 3; gie = true; umem_val = 0; reg_val = 0x1; timerA_counter = 0; mode = UM })]
]

let output_b4_encl0_int_orig = [
  [(OJmpOut { k = 3; gie = false; umem_val = 0; reg_val = 0x2; timerA_counter = 0; mode = UM })]
]

let output_b4_encl1_int_orig = [
  [(OJmpOut { k = 3; gie = false; umem_val = 0; reg_val = 0x1; timerA_counter = 0; mode = UM })]
]

let output_b4_encl_int_last = [
  [OReset]
]

(* B6 tests *)
let input_b6_encl_noint = "
att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (mov #42, &unprot_mem; nop) (nop; mov #42, &unprot_mem);
enc: jmp #enc_e"

let input_b6_encl_noint_last = "
att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (mov #42, &unprot_mem; nop) (nop; mov #42, &unprot_mem)"

let input_b6_encl_int = input_b6_encl_noint_last
let input_b6_encl_int_last = input_b6_encl_noint_last

let output_b6_encl_noint = [
  [(OJmpOut { k = 3; gie = true; umem_val = 42; reg_val = 0; timerA_counter = 0x4; mode = UM })]
]

let output_b6_encl0_int_orig = [
  [
    (
      OTime_Handle (
        { k = 7; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0x4; mode = PM },
        { k = 4; gie = false; umem_val = 0x2a; reg_val = 0; timerA_counter = 0x2; mode = UM }
      )
    )
  ]
]

let output_b6_encl1_int_orig = [
  [
    (
      OTime_Handle (
        { k = 7; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0x4; mode = PM },
        { k = 4; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x2; mode = UM }
      )
    )
  ]
]


let output_b6_encl_noint_last = [[OReset]]

let output_b6_encl0_int_last = [[OReset]]
let output_b6_encl1_int_last = [
  [
    (OTime_Handle (
      { k = 3; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = PM },
      { k = 9; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x3; mode = UM }
      )
    )
  ]
]


(* B7 tests *)
let input_b7_encl_noint = "
att: timer_enable 4;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (dint; nop) (nop; dint);
enc: jmp #enc_e"

let input_b7_encl_int = input_b7_encl_noint
let input_b7_encl_int_last = input_b7_encl_int

let output_b7_encl_noint =   [
  [(OJmpOut { k = 3; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x5; mode = UM })]
]

let output_b7_encl0_int_orig = [
  [(OJmpOut { k = 3; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x5; mode = UM })]
]

let output_b7_encl1_int_orig = [
  [
    (
      OTime_Handle (
        { k = 4; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = PM },
        { k = 8; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x1; mode = UM }
      )
    )
  ]
]

let output_b7_encl_noint_last = [
  [(OJmpOut { k = 3; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0x5; mode = UM })]
]

let output_b7_encl_int_last = [
  [
    (
      OTime_Handle (
        { k = 4; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = PM },
        { k = 9; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x2; mode = UM }
      )
    )
  ]
]


(* B8 tests *)
let input_b8_encl_noint = "
att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (mov &unprot_mem, r8; nop) (nop; mov &unprot_mem, r8);
enc: jmp #enc_e"

let input_b8_encl_noint_last = "
att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (mov &unprot_mem, r8; nop) (nop; mov &unprot_mem, r8)"

let input_b8_encl_int = input_b8_encl_noint_last
let input_b8_encl_int_last = input_b8_encl_noint_last

let output_b8_encl_noint = [
  [(OJmpOut { k = 3; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0x2; mode = UM })]
]

let output_b8_encl0_int_orig = [
  [
    (
      OTime_Handle (
        { k = 7; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0x2; mode = PM },
        { k = 4; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x2; mode = UM }
      )
    )
  ]
]

let output_b8_encl1_int_orig = [
  [
    (
      OTime_Handle (
        { k = 7; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0x2; mode = PM },
        { k = 4; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x2; mode = UM }
      )
    )
  ]
]


let output_b8_encl_noint_last = [[OReset]]

let output_b8_encl0_int_last = [[OReset]]
let output_b8_encl1_int_last = [
  [
    (OTime_Handle (
      { k = 3; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = PM },
      { k = 9; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x3; mode = UM }
      )
    )
  ]
]


(* B9: reset inside enclaves should be forbidden and should cause the execution of an exception handler *)
let input_b9_encl_noint = "att: timer_enable 3;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (rst; nop) (nop; rst)"

let input_b9_encl_noint_last = input_b9_encl_noint
let input_b9_encl_int = input_b9_encl_noint_last
let input_b9_encl_int_last = input_b9_encl_noint_last

let output_b9_encl_noint = [[OReset]]
let output_b9_encl0_int_orig = [[OReset]]

let output_b9_encl1_int_orig = [
  [
    (
      OTime_Handle (
        { k = 7; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0x4; mode = PM },
        { k = 4; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x2; mode = UM }
      )
    )
  ]
]


let output_b9_encl_noint_last = [[OReset]]

let output_b9_encl0_int_last = [[OReset]]
let output_b9_encl1_int_last = [
  [
    (OTime_Handle (
      { k = 3; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = PM },
      { k = 9; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0x3; mode = UM }
      )
    )
  ]
]

(* A: Jump in data part of enclave. After the violation the enclave starts execting at address 0x0240 and keeps going and executing the piece of code *after* the instruction that caused the violation.
With timer_enable 5, the add in the then branch never executes because after returning from the interrupt the control goes back to the attacker and the computation divereges. In the other case, the CPU performs the addition before doing the ISR and when returning from there, the value is visible to the attacker.
*)
let input_a_encl_noint = "att: timer_enable 4;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (jmp #data_s; add #1, r4) (add #1, r4; jmp #data_s);
att: nop"

let input_a_encl_int = "att: timer_enable 4;
att: create <enc_s, enc_e, data_s, data_e>;
att: jin enc_s;
enc: cmp ?, r4;
enc: ifz (jmp #data_s; add #1, r4) (add #1, r4; jmp #data_s);
att: reti;
att: nop"

let output_a_encl_noint = [[OMaybeDiverge]]
let output_a_encl0_int = [
  [
    (OTime { k = 14; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = UM });
    (OReti { k = 3; gie = true; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = UM })
  ];
  [OMaybeDiverge]
]

let output_a_encl1_int = [
  [
    (OTime { k = 14; gie = false; umem_val = 0; reg_val = 0; timerA_counter = 0; mode = UM });
    (OReti { k = 4; gie = true; umem_val = 0; reg_val = 0x1; timerA_counter = 0; mode = UM })
  ];
  [OMaybeDiverge]
]


(* A2': Jump directly in the middle of an enclave data with value a valid opcode *)
(* A2'': Jump directly in the middle of an enclave data with value 0 *)
