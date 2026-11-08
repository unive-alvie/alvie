// The enclave moves the secret into a register but does not branch on it: nothing it does depends on the secret.
prepare { (timer 1 | timer 2 | timer 3 | eps); call };
enclave { mov r0, ?; nop; mov r1, 1; ret };
isr { reti };
cleanup { halt };
