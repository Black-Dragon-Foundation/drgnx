-- a small schema
CREATE TABLE users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE VIEW recent AS
SELECT id, name FROM users WHERE created_at > '2026-01-01' ORDER BY id LIMIT 10;
