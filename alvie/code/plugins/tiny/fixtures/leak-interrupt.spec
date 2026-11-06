// bz r0; pad r0 takes three cycles whatever the secret, so the time of the enclave tells nothing. But the timer can
// interrupt it in the middle: where the interrupt lands, and its latency, tell the secret (as Nemesis on Sancus).
prepare { (timer 1 | timer 2 | timer 3 | eps); call };
enclave { mov r0, ?; bz r0; pad r0; ret };
isr { reti };
cleanup { halt };
