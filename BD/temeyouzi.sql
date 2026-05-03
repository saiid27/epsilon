-- PostgreSQL schema for Epsilon Education

CREATE TABLE IF NOT EXISTS users (
  id SERIAL PRIMARY KEY,
  username VARCHAR(100) NOT NULL UNIQUE,
  phone VARCHAR(30) NOT NULL UNIQUE,
  password VARCHAR(64) NOT NULL,
  role VARCHAR(20) NOT NULL DEFAULT 'student',
  level VARCHAR(40),
  subject VARCHAR(80),
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  phone_verified BOOLEAN NOT NULL DEFAULT FALSE,
  payment_image VARCHAR(255),
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS verification_codes (
  id SERIAL PRIMARY KEY,
  phone VARCHAR(30) NOT NULL,
  code VARCHAR(10) NOT NULL,
  purpose VARCHAR(30) NOT NULL,
  used BOOLEAN NOT NULL DEFAULT FALSE,
  expires_at TIMESTAMP NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_verification_codes_lookup
  ON verification_codes (phone, purpose, code, used, expires_at);

CREATE TABLE IF NOT EXISTS courses (
  id SERIAL PRIMARY KEY,
  code VARCHAR(40) NOT NULL UNIQUE,
  title VARCHAR(100) NOT NULL,
  subtitle VARCHAR(255) NOT NULL DEFAULT '',
  description TEXT,
  badge VARCHAR(40) DEFAULT '',
  icon VARCHAR(20) DEFAULT '📘',
  theme VARCHAR(30) DEFAULT 'blue',
  sort_order INT DEFAULT 0,
  active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS course_subjects (
  id SERIAL PRIMARY KEY,
  course_code VARCHAR(40) NOT NULL REFERENCES courses(code) ON DELETE CASCADE,
  subject VARCHAR(80) NOT NULL,
  sort_order INT DEFAULT 0,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (course_code, subject)
);

CREATE TABLE IF NOT EXISTS lessons (
  id SERIAL PRIMARY KEY,
  subject VARCHAR(80) NOT NULL,
  chapter_title VARCHAR(255) NOT NULL,
  level VARCHAR(40) NOT NULL,
  video_file VARCHAR(255),
  pdf_file VARCHAR(255),
  video_url TEXT,
  uploaded_by INT REFERENCES users(id) ON DELETE SET NULL,
  uploaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_lessons_level_subject
  ON lessons (level, subject, uploaded_at DESC);

CREATE INDEX IF NOT EXISTS idx_lessons_uploaded_by
  ON lessons (uploaded_by, uploaded_at DESC);
