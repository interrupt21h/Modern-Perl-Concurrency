UPDATE protected_resource
SET payload = ?, last_fence = ?
WHERE resource_id = ? AND last_fence <= ?;   -- use < for one write per generation
-- Require one affected row; zero means a newer holder exists.
