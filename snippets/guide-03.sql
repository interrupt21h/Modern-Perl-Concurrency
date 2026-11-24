UPDATE account
SET cents = cents - 100
WHERE id = 1 AND cents >= 100;
-- Require affected rows = 1; zero means insufficient funds or no row.
