SHOW ENGINE INNODB STATUS;
SELECT * FROM performance_schema.data_lock_waits;
SELECT * FROM performance_schema.data_locks;
SELECT * FROM performance_schema.metadata_locks
 WHERE LOCK_STATUS = 'PENDING';
SELECT * FROM sys.innodb_lock_waits;
SELECT * FROM performance_schema.processlist;  -- avoids the global mutex
