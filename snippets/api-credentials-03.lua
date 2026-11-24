-- KEYS: old token, family, successor token
-- ARGV: successor hash, grace window (ms), refresh TTL (s)
if redis.call('EXISTS', KEYS[2]) == 0 then
    return 'revoked'
end

local rec = redis.call('HMGET', KEYS[1], 'state', 'used_at', 'successor', 'user')
if not rec[1] then
    return 'unknown'
end

local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
if rec[1] == 'active' then
    redis.call('HSET', KEYS[1],
        'state', 'used', 'used_at', now, 'successor', ARGV[1])
    redis.call('HSET', KEYS[3], 'state', 'active', 'user', rec[4])
    redis.call('EXPIRE', KEYS[3], ARGV[3])
    redis.call('HSET', KEYS[2], 'current', ARGV[1])
    redis.call('EXPIRE', KEYS[2], ARGV[3])
    return 'rotated'
end
if rec[3] == ARGV[1] and now - tonumber(rec[2]) <= tonumber(ARGV[2]) then
    return 'replay'
end
redis.call('DEL', KEYS[2])
return 'reuse'
