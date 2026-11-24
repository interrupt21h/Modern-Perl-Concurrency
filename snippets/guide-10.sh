# Local examples always run; service examples run when configured.
export DB_DSN='DBI:mysql:database=concurrency_lab;host=127.0.0.1'
export DB_USER=lab DB_PASS=...            # disposable database only
export REDIS_SERVER=127.0.0.1:6379 MEMCACHED_SERVER=127.0.0.1:11211
mysql -u lab -p concurrency_lab < examples/schema.sql
./run-tests.sh
