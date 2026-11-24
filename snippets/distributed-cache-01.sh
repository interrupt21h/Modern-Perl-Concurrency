TOKEN=$(openssl rand -hex 16)                          # unique per acquisition
redis-cli SET 'lease:{report}' "$TOKEN" NX PX 10000      # acquire
redis-cli EVAL "if redis.call('GET',KEYS[1]) == ARGV[1] then \
  return redis.call('DEL',KEYS[1]) else return 0 end" \
  1 'lease:{report}' "$TOKEN"                            # release, any version
redis-cli DELEX 'lease:{report}' IFEQ "$TOKEN"           # release, Redis 8.4+
redis-cli DELIFEQ 'lease:{report}' "$TOKEN"              # release, Valkey 9.0+
redis-cli SET 'lease:{report}' "$TOKEN" IFEQ "$TOKEN" PX 10000
                                       # renew, Redis 8.4+ / Valkey 8.1+
