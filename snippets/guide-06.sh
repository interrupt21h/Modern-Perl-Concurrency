cpanm DBI DBD::mysql
mysql -u lab -p concurrency_lab < examples/schema.sql
export DB_DSN='DBI:mysql:database=concurrency_lab;host=127.0.0.1'
export DB_USER=lab
# Inject DB_PASS using your approved secret mechanism.
perl examples/11-mysql-transfer.pl 100
