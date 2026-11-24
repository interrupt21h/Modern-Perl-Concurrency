cpanm Redis Cache::Memcached::Fast Future::AsyncAwait IO::Async
# On an isolated development host, as an unprivileged user:
redis-server --bind 127.0.0.1 --port 6379 --save '' --appendonly no &
memcached -l 127.0.0.1 -p 11211 -U 0 &
export REDIS_SERVER=127.0.0.1:6379 MEMCACHED_SERVER=127.0.0.1:11211
./run-tests.sh
