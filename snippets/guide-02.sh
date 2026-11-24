$ strace -f -c -e trace=futex perl examples/01-mutex.pl
40000
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ----------------
100.00    0.003375          62        54        10 futex
