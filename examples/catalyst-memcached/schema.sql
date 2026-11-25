CREATE TABLE IF NOT EXISTS mc_tokens (
 token_hash CHAR(64) PRIMARY KEY,
 principal VARCHAR(64) NOT NULL,
 scope VARCHAR(16) NOT NULL,
 expires_at BIGINT NOT NULL
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS mc_orders (
 principal VARCHAR(64) NOT NULL,
 request_key VARCHAR(64) NOT NULL,
 amount INT UNSIGNED NOT NULL,
 PRIMARY KEY (principal, request_key)
) ENGINE=InnoDB;
