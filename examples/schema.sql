-- Disposable laboratory schema for examples 10-12, 18 and 29.
-- MySQL 8.0.16+ (enforced CHECK constraints); baseline 8.4 LTS / 9.7 LTS.
DROP TABLE IF EXISTS job_effect, job, protected_resource, document, account;

CREATE TABLE account (
    id    BIGINT PRIMARY KEY,
    cents BIGINT NOT NULL,
    CONSTRAINT account_nonnegative CHECK (cents >= 0)
) ENGINE=InnoDB;
INSERT INTO account VALUES (1, 10000), (2, 10000);

-- Visibility-timeout queue: a pending job is claimable once visible_at has
-- passed. Claiming pushes visible_at forward (the lease); an abandoned
-- lease therefore becomes claimable again without a separate sweeper.
CREATE TABLE job (
    id           BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    payload      JSON NOT NULL,
    state        ENUM('pending','done','dead') NOT NULL DEFAULT 'pending',
    visible_at   DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    owner        VARCHAR(64) NULL,
    attempt      INT UNSIGNED NOT NULL DEFAULT 0,
    max_attempts INT UNSIGNED NOT NULL DEFAULT 5,
    last_error   VARCHAR(255) NULL,
    INDEX claim_scan (state, visible_at, id)
) ENGINE=InnoDB;

-- Side effect recorded in the same transaction as completion; the unique
-- key makes a duplicate effect impossible even if two workers race.
CREATE TABLE job_effect (
    job_id  BIGINT UNSIGNED PRIMARY KEY,
    attempt INT UNSIGNED NOT NULL,
    result  JSON NOT NULL,
    CONSTRAINT effect_job FOREIGN KEY (job_id) REFERENCES job (id)
) ENGINE=InnoDB;

INSERT INTO job (payload)
WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20)
SELECT JSON_OBJECT('n', n) FROM seq;

-- Destination that enforces fencing tokens (example 18).
CREATE TABLE protected_resource (
    resource_id VARCHAR(64) PRIMARY KEY,
    payload     VARCHAR(255) NOT NULL,
    last_fence  BIGINT UNSIGNED NOT NULL DEFAULT 0
) ENGINE=InnoDB;
INSERT INTO protected_resource VALUES ('report', 'initial', 0);

-- Optimistic concurrency (example 29): every change increments version, and
-- an UPDATE succeeds only against the version the writer read.
CREATE TABLE document (
    id      BIGINT PRIMARY KEY,
    body    TEXT NOT NULL,
    version INT UNSIGNED NOT NULL DEFAULT 0
) ENGINE=InnoDB;
INSERT INTO document VALUES (1, '', 0);
