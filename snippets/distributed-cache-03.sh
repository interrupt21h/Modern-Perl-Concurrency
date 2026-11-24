ACL SETUSER lease-worker reset on >${LEASE_WORKER_SECRET} \
    ~lease:* ~fence:* ~sem:* resetchannels -@all \
    +evalsha +script|load +get +set +incr +pexpire +pexpireat +del \
    +zadd +zrem +zcard +zscore +zrange +zremrangebyscore +time \
    +client|setname +ping
