-- MySQL/MariaDB schema for the Wolf site (replaces supabase.sql). Applied once by api/install.php.

CREATE TABLE IF NOT EXISTS users (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(190) NOT NULL UNIQUE,
  pass_hash VARCHAR(255) NOT NULL,
  first_name VARCHAR(60),
  last_name VARCHAR(60),
  phone VARCHAR(24),
  invite VARCHAR(40),
  is_admin TINYINT(1) NOT NULL DEFAULT 0,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- code is case-sensitive (utf8mb4_bin), like the Supabase version
CREATE TABLE IF NOT EXISTS invites (
  code VARCHAR(40) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL PRIMARY KEY,
  note VARCHAR(190),
  max_uses INT NOT NULL DEFAULT 1,
  uses INT NOT NULL DEFAULT 0,
  expires_at DATETIME NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS party (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  title VARCHAR(190) NOT NULL,
  theme VARCHAR(190),
  starts_at DATETIME NOT NULL,
  ends_at DATETIME NULL,
  venue VARCHAR(190),
  address VARCHAR(255),
  city VARCHAR(120),
  lat DOUBLE NULL,
  lon DOUBLE NULL,
  directions TEXT,
  entry VARCHAR(255),
  capacity INT NULL,
  dress_code VARCHAR(255),
  dress_notes TEXT,
  rules TEXT,
  status ENUM('sold_out','cancelled') NULL,
  published TINYINT(1) NOT NULL DEFAULT 1,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- internal notes live apart from party so a members-facing query can never return them
CREATE TABLE IF NOT EXISTS party_notes (
  party_id INT UNSIGNED NOT NULL PRIMARY KEY,
  notes TEXT,
  FOREIGN KEY (party_id) REFERENCES party (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS resets (
  token_hash CHAR(64) NOT NULL PRIMARY KEY,
  user_id INT UNSIGNED NOT NULL,
  expires_at DATETIME NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS rate_limits (
  k VARCHAR(80) NOT NULL,
  t INT UNSIGNED NOT NULL,
  INDEX (k, t)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
