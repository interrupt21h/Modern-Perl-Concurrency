START TRANSACTION;
SELECT id, payload, attempt
FROM delivery_job
WHERE status = 'ready'
   OR (status = 'running' AND lease_until < UTC_TIMESTAMP(6))
ORDER BY id
LIMIT 1 FOR UPDATE SKIP LOCKED;

-- Use selected id; roll back if no row is returned.
UPDATE delivery_job
SET status = 'running', attempt = attempt + 1,
    lease_until = UTC_TIMESTAMP(6) + INTERVAL 60 SECOND
WHERE id = ?;
COMMIT;

-- Deliver outside the transaction, using a stable event ID.
-- Bind the selected id and its incremented attempt number.
UPDATE delivery_job
SET status = 'done', lease_until = NULL
WHERE id = ? AND status = 'running' AND attempt = ?;
-- Zero changed rows: this attempt no longer owns the job.
