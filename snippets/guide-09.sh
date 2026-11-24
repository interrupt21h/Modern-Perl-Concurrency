ps -eLf                       # threads per process
lslocks                       # flock, POSIX and OFD locks
ipcs -s                       # System V semaphore sets
strace -f -e trace=futex,flock,fcntl,semop,semtimedop -p PID
redis-cli --latency-history   # Redis round-trip latency
# Attach tracers only with authorization; tracing adds overhead.
