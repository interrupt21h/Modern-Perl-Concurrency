START TRANSACTION;
SELECT * FROM account WHERE id = 1 FOR UPDATE NOWAIT;
-- ERROR 3572: the requested row is already locked.
ROLLBACK;
