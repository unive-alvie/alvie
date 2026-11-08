// The enclave branches on the secret with bz: it takes two cycles if the secret is 0, one otherwise, so the time it
// takes tells the secret, with or without interrupts.
prepare { (timer 1 | timer 2 | timer 3 | eps); call };
enclave { mov r0, ?; bz r0; ret };
isr { reti };
cleanup { halt };
