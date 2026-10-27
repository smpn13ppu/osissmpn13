-- =====================================================================
-- OSIS SMPN 13 PENAJAM PASER UTARA
-- Supabase SQL Schema + RPC Functions
-- Jalankan seluruh skrip ini melalui Supabase SQL Editor
-- =====================================================================

-- ── EKSTENSI ──────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ── TABEL ─────────────────────────────────────────────────────────────

-- 1. election_config
CREATE TABLE IF NOT EXISTS election_config (
  id            int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  is_open       boolean NOT NULL DEFAULT false,
  admin_password text NOT NULL,
  election_title text NOT NULL DEFAULT 'Pemilihan Ketua OSIS',
  started_at    timestamptz,
  closed_at     timestamptz,
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- 2. candidates
CREATE TABLE IF NOT EXISTS candidates (
  id            bigserial PRIMARY KEY,
  number        int NOT NULL,
  name          text NOT NULL,
  chairman      text NOT NULL DEFAULT '',
  vice_chairman text NOT NULL DEFAULT '',
  photo_url     text,
  vision        text,
  mission       text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- 3. voters
CREATE TABLE IF NOT EXISTS voters (
  id            bigserial PRIMARY KEY,
  nisn          text NOT NULL UNIQUE,
  name          text NOT NULL,
  class         text NOT NULL DEFAULT '',
  gender        text NOT NULL DEFAULT '',
  religion      text NOT NULL DEFAULT '',
  has_voted     boolean NOT NULL DEFAULT false,
  voted_at      timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- Pastikan kolom baru ada jika tabel sudah terlanjur dibuat
ALTER TABLE voters ADD COLUMN IF NOT EXISTS gender text NOT NULL DEFAULT '';
ALTER TABLE voters ADD COLUMN IF NOT EXISTS religion text NOT NULL DEFAULT '';

-- 4. votes
CREATE TABLE IF NOT EXISTS votes (
  id            bigserial PRIMARY KEY,
  candidate_id  bigint NOT NULL REFERENCES candidates(id) ON DELETE CASCADE,
  voter_nisn    text NOT NULL REFERENCES voters(nisn) ON DELETE CASCADE,
  voted_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE(voter_nisn)
);

-- 5. admin_sessions
CREATE TABLE IF NOT EXISTS admin_sessions (
  token         uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL DEFAULT (now() + interval '8 hours')
);

-- ── ROW LEVEL SECURITY (DENY ALL) ────────────────────────────────────
ALTER TABLE election_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE candidates      ENABLE ROW LEVEL SECURITY;
ALTER TABLE voters          ENABLE ROW LEVEL SECURITY;
ALTER TABLE votes           ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_sessions  ENABLE ROW LEVEL SECURITY;

-- Tidak ada policy = akses langsung via anon key ditolak sepenuhnya

-- ── DATA AWAL ─────────────────────────────────────────────────────────
-- Sandi default: guru13  (ubah sesuai kebutuhan)
INSERT INTO election_config (id, is_open, admin_password, election_title)
VALUES (
  1,
  false,
  crypt('guru13', gen_salt('bf')),
  'Pemilihan Ketua OSIS SMPN 13 Penajam Paser Utara'
)
ON CONFLICT (id) DO NOTHING;

-- =====================================================================
-- HELPER: Validasi token admin
-- =====================================================================
CREATE OR REPLACE FUNCTION _is_admin(p_token uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM admin_sessions
    WHERE token = p_token
      AND expires_at > now()
  );
END;
$$;

-- =====================================================================
-- RPC PUBLIK
-- =====================================================================

-- ── check_nisn ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_nisn(p_nisn text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_voter   voters%ROWTYPE;
  v_is_open boolean;
BEGIN
  SELECT is_open INTO v_is_open FROM election_config WHERE id = 1;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Konfigurasi pemilihan tidak ditemukan.');
  END IF;

  IF NOT v_is_open THEN
    RETURN json_build_object('ok', false, 'error', 'Pemilihan belum dibuka atau telah ditutup.');
  END IF;

  SELECT * INTO v_voter FROM voters WHERE nisn = p_nisn;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'NISN tidak ditemukan dalam daftar pemilih.');
  END IF;

  IF v_voter.has_voted THEN
    RETURN json_build_object('ok', false, 'error', 'NISN ini sudah digunakan untuk memilih.');
  END IF;

  RETURN json_build_object(
    'ok', true,
    'data', json_build_object(
      'nisn', v_voter.nisn,
      'name', v_voter.name,
      'class', v_voter.class
    )
  );
END;
$$;

-- ── get_candidates ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_candidates()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rows json;
BEGIN
  SELECT json_agg(
    json_build_object(
      'id', id,
      'number', number,
      'name', name,
      'chairman', chairman,
      'vice_chairman', vice_chairman,
      'photo_url', photo_url,
      'vision', vision,
      'mission', mission
    ) ORDER BY number
  )
  INTO v_rows
  FROM candidates;

  RETURN json_build_object('ok', true, 'data', COALESCE(v_rows, '[]'::json));
END;
$$;

-- ── cast_vote ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cast_vote(p_nisn text, p_candidate_id bigint)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_voter   voters%ROWTYPE;
  v_is_open boolean;
BEGIN
  SELECT is_open INTO v_is_open FROM election_config WHERE id = 1;
  IF NOT v_is_open THEN
    RETURN json_build_object('ok', false, 'error', 'Pemilihan sudah ditutup.');
  END IF;

  -- Kunci row voter untuk mencegah race condition
  SELECT * INTO v_voter FROM voters WHERE nisn = p_nisn FOR UPDATE;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'NISN tidak ditemukan.');
  END IF;

  IF v_voter.has_voted THEN
    RETURN json_build_object('ok', false, 'error', 'Anda sudah memberikan suara.');
  END IF;

  -- Pastikan kandidat ada
  IF NOT EXISTS (SELECT 1 FROM candidates WHERE id = p_candidate_id) THEN
    RETURN json_build_object('ok', false, 'error', 'Kandidat tidak ditemukan.');
  END IF;

  -- Simpan suara
  INSERT INTO votes (candidate_id, voter_nisn) VALUES (p_candidate_id, p_nisn);

  -- Update status voter
  UPDATE voters SET has_voted = true, voted_at = now() WHERE nisn = p_nisn;

  RETURN json_build_object('ok', true, 'data', json_build_object('message', 'Suara berhasil dicatat.'));
END;
$$;

-- =====================================================================
-- RPC ADMIN
-- =====================================================================

-- ── admin_login ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_login(p_password text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_hash text;
  v_token uuid;
BEGIN
  SELECT admin_password INTO v_hash FROM election_config WHERE id = 1;

  IF NOT FOUND THEN
    RETURN json_build_object('ok', false, 'error', 'Konfigurasi tidak ditemukan.');
  END IF;

  IF v_hash != crypt(p_password, v_hash) THEN
    RETURN json_build_object('ok', false, 'error', 'Sandi salah.');
  END IF;

  INSERT INTO admin_sessions DEFAULT VALUES RETURNING token INTO v_token;

  RETURN json_build_object('ok', true, 'data', json_build_object('token', v_token));
END;
$$;

-- ── admin_get_config ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_get_config(p_token uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_cfg election_config%ROWTYPE;
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  SELECT * INTO v_cfg FROM election_config WHERE id = 1;

  RETURN json_build_object(
    'ok', true,
    'data', json_build_object(
      'is_open', v_cfg.is_open,
      'election_title', v_cfg.election_title,
      'started_at', v_cfg.started_at,
      'closed_at', v_cfg.closed_at
    )
  );
END;
$$;

-- ── admin_toggle_election ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_toggle_election(p_token uuid, p_open boolean)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  UPDATE election_config SET
    is_open    = p_open,
    started_at = CASE WHEN p_open = true AND started_at IS NULL THEN now() ELSE started_at END,
    closed_at  = CASE WHEN p_open = false THEN now() ELSE NULL END,
    updated_at = now()
  WHERE id = 1;

  RETURN json_build_object('ok', true, 'data', json_build_object('is_open', p_open));
END;
$$;

-- ── admin_get_candidates ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_get_candidates(p_token uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rows json;
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  SELECT json_agg(
    json_build_object(
      'id', id, 'number', number, 'name', name,
      'chairman', chairman, 'vice_chairman', vice_chairman,
      'photo_url', photo_url, 'vision', vision, 'mission', mission,
      'created_at', created_at
    ) ORDER BY number
  ) INTO v_rows FROM candidates;

  RETURN json_build_object('ok', true, 'data', COALESCE(v_rows, '[]'::json));
END;
$$;

-- ── admin_save_candidate ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_save_candidate(p_token uuid, p_candidate json)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_id          bigint;
  v_number      int;
  v_name        text;
  v_chairman    text;
  v_vice        text;
  v_photo       text;
  v_vision      text;
  v_mission     text;
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  v_id       := (p_candidate->>'id')::bigint;
  v_number   := (p_candidate->>'number')::int;
  v_name     := p_candidate->>'name';
  v_chairman := COALESCE(p_candidate->>'chairman', '');
  v_vice     := COALESCE(p_candidate->>'vice_chairman', '');
  v_photo    := p_candidate->>'photo_url';
  v_vision   := COALESCE(p_candidate->>'vision', '');
  v_mission  := COALESCE(p_candidate->>'mission', '');

  IF v_number IS NULL OR v_name IS NULL OR trim(v_name) = '' THEN
    RETURN json_build_object('ok', false, 'error', 'Nomor urut dan nama wajib diisi.');
  END IF;

  IF v_id IS NOT NULL THEN
    UPDATE candidates SET
      number        = v_number,
      name          = v_name,
      chairman      = v_chairman,
      vice_chairman = v_vice,
      photo_url     = v_photo,
      vision        = v_vision,
      mission       = v_mission
    WHERE id = v_id;
  ELSE
    INSERT INTO candidates (number, name, chairman, vice_chairman, photo_url, vision, mission)
    VALUES (v_number, v_name, v_chairman, v_vice, v_photo, v_vision, v_mission)
    RETURNING id INTO v_id;
  END IF;

  RETURN json_build_object('ok', true, 'data', json_build_object('id', v_id));
END;
$$;

-- ── admin_delete_candidate ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_delete_candidate(p_token uuid, p_candidate_id bigint)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  DELETE FROM candidates WHERE id = p_candidate_id;

  RETURN json_build_object('ok', true, 'data', json_build_object('deleted', p_candidate_id));
END;
$$;

-- ── admin_import_voters ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_import_voters(p_token uuid, p_voters text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rows     json;
  v_row      json;
  v_count    int := 0;
  v_inserted int := 0;
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  v_rows := p_voters::json;

  FOR v_row IN SELECT * FROM json_array_elements(v_rows)
  LOOP
    v_count := v_count + 1;
    BEGIN
      INSERT INTO voters (nisn, name, class, gender, religion)
      VALUES (
        trim(v_row->>'nisn'),
        trim(v_row->>'name'),
        trim(v_row->>'class'),
        COALESCE(trim(v_row->>'gender'), ''),
        COALESCE(trim(v_row->>'religion'), '')
      )
      ON CONFLICT (nisn) DO UPDATE
        SET name     = EXCLUDED.name,
            class    = EXCLUDED.class,
            gender   = EXCLUDED.gender,
            religion = EXCLUDED.religion;

      v_inserted := v_inserted + 1;
    EXCEPTION WHEN OTHERS THEN
      -- lewati baris yang bermasalah
    END;
  END LOOP;

  RETURN json_build_object(
    'ok', true,
    'data', json_build_object('imported', v_inserted, 'total', v_count)
  );
END;
$$;

-- ── admin_get_voters ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_get_voters(
  p_token  uuid,
  p_limit  int  DEFAULT 50,
  p_offset int  DEFAULT 0,
  p_search text DEFAULT ''
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rows  json;
  v_total int;
  v_where text := '';
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  IF p_search IS NOT NULL AND trim(p_search) != '' THEN
    -- Gunakan ILIKE untuk pencarian case-insensitive
    SELECT COUNT(*) INTO v_total FROM voters
    WHERE nisn ILIKE '%' || p_search || '%'
       OR name ILIKE '%' || p_search || '%'
       OR class ILIKE '%' || p_search || '%';

    SELECT json_agg(
      json_build_object(
        'id', id, 'nisn', nisn, 'name', name,
        'class', class, 'gender', gender, 'religion', religion,
        'has_voted', has_voted, 'voted_at', voted_at
      ) ORDER BY name
    )
    INTO v_rows
    FROM (
      SELECT * FROM voters
      WHERE nisn ILIKE '%' || p_search || '%'
         OR name ILIKE '%' || p_search || '%'
         OR class ILIKE '%' || p_search || '%'
      ORDER BY name
      LIMIT p_limit OFFSET p_offset
    ) sub;
  ELSE
    SELECT COUNT(*) INTO v_total FROM voters;

    SELECT json_agg(
      json_build_object(
        'id', id, 'nisn', nisn, 'name', name,
        'class', class, 'gender', gender, 'religion', religion,
        'has_voted', has_voted, 'voted_at', voted_at
      ) ORDER BY name
    )
    INTO v_rows
    FROM (
      SELECT * FROM voters ORDER BY name LIMIT p_limit OFFSET p_offset
    ) sub;
  END IF;

  RETURN json_build_object(
    'ok', true,
    'data', json_build_object(
      'rows', COALESCE(v_rows, '[]'::json),
      'total', COALESCE(v_total, 0)
    )
  );
END;
$$;

-- ── admin_delete_voter ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_delete_voter(p_token uuid, p_voter_id bigint)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  DELETE FROM voters WHERE id = p_voter_id;

  RETURN json_build_object('ok', true, 'data', json_build_object('deleted', p_voter_id));
END;
$$;

-- ── admin_delete_voters_bulk ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_delete_voters_bulk(p_token uuid, p_voter_ids bigint[])
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  DELETE FROM voters WHERE id = ANY(p_voter_ids);

  RETURN json_build_object('ok', true, 'data', json_build_object('deleted_count', array_length(p_voter_ids, 1)));
END;
$$;

-- ── admin_reset_votes ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_reset_votes(p_token uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  DELETE FROM votes WHERE id IS NOT NULL;
  UPDATE voters SET has_voted = false, voted_at = NULL WHERE id IS NOT NULL;

  RETURN json_build_object('ok', true, 'data', json_build_object('message', 'Semua suara telah direset.'));
END;
$$;

-- ── admin_quick_count ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_quick_count(p_token uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total_voters int;
  v_total_votes  int;
  v_candidates   json;
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  SELECT COUNT(*) INTO v_total_voters FROM voters;
  SELECT COUNT(*) INTO v_total_votes FROM votes;

  SELECT json_agg(
    json_build_object(
      'id', c.id,
      'number', c.number,
      'name', c.name,
      'chairman', c.chairman,
      'vice_chairman', c.vice_chairman,
      'photo_url', c.photo_url,
      'vote_count', COALESCE(v.cnt, 0)
    ) ORDER BY c.number
  )
  INTO v_candidates
  FROM candidates c
  LEFT JOIN (
    SELECT candidate_id, COUNT(*) AS cnt FROM votes GROUP BY candidate_id
  ) v ON v.candidate_id = c.id;

  RETURN json_build_object(
    'ok', true,
    'data', json_build_object(
      'total_voters', v_total_voters,
      'total_votes', v_total_votes,
      'candidates', COALESCE(v_candidates, '[]'::json)
    )
  );
END;
$$;

-- ── admin_analytics ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_analytics(p_token uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total_voters int;
  v_total_votes  int;
  v_cand_votes   json;
  v_part_class   json;
  v_votes_class  json;
  v_trend        json;
  v_votes_gender json;
  v_part_gender  json;
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  -- Total
  SELECT COUNT(*) INTO v_total_voters FROM voters;
  SELECT COUNT(*) INTO v_total_votes  FROM votes;

  -- Perolehan suara per kandidat
  SELECT json_agg(
    json_build_object(
      'id', c.id,
      'number', c.number,
      'name', c.name,
      'chairman', c.chairman,
      'vice_chairman', c.vice_chairman,
      'photo_url', c.photo_url,
      'vote_count', COALESCE(v.cnt, 0)
    ) ORDER BY c.number
  )
  INTO v_cand_votes
  FROM candidates c
  LEFT JOIN (
    SELECT candidate_id, COUNT(*) AS cnt FROM votes GROUP BY candidate_id
  ) v ON v.candidate_id = c.id;

  -- Partisipasi per kelas
  SELECT json_agg(
    json_build_object(
      'class_name', pc.class,
      'voted', pc.voted,
      'not_voted', pc.not_voted,
      'total', pc.total
    ) ORDER BY pc.class
  )
  INTO v_part_class
  FROM (
    SELECT
      class,
      SUM(CASE WHEN has_voted THEN 1 ELSE 0 END) AS voted,
      SUM(CASE WHEN NOT has_voted THEN 1 ELSE 0 END) AS not_voted,
      COUNT(*) AS total
    FROM voters
    GROUP BY class
  ) pc;

  -- Suara per kelas & kandidat
  SELECT json_agg(
    json_build_object(
      'class_name', vt.class,
      'candidate_id', vt.candidate_id,
      'vote_count', vt.cnt
    ) ORDER BY vt.class, vt.candidate_id
  )
  INTO v_votes_class
  FROM (
    SELECT vo.class, v.candidate_id, COUNT(*) AS cnt
    FROM votes v
    JOIN voters vo ON vo.nisn = v.voter_nisn
    GROUP BY vo.class, v.candidate_id
  ) vt;

  -- Tren suara per jam
  SELECT json_agg(
    json_build_object(
      'hour', to_char(hour_bucket, 'HH24'),
      'vote_count', cnt
    ) ORDER BY hour_bucket
  )
  INTO v_trend
  FROM (
    SELECT date_trunc('hour', voted_at) AS hour_bucket, COUNT(*) AS cnt
    FROM votes
    GROUP BY hour_bucket
  ) t;

  -- Suara per Gender & Paslon
  SELECT json_agg(
    json_build_object(
      'gender', vg.gender_clean,
      'candidate_id', vg.candidate_id,
      'candidate_number', c.number,
      'candidate_name', c.name,
      'vote_count', vg.cnt
    ) ORDER BY c.number, vg.gender_clean
  )
  INTO v_votes_gender
  FROM (
    SELECT
      CASE 
        WHEN LOWER(TRIM(vo.gender)) LIKE 'l%' THEN 'Laki-laki'
        WHEN LOWER(TRIM(vo.gender)) LIKE 'p%' THEN 'Perempuan'
        ELSE 'Lainnya'
      END AS gender_clean,
      v.candidate_id,
      COUNT(*) AS cnt
    FROM votes v
    JOIN voters vo ON vo.nisn = v.voter_nisn
    GROUP BY gender_clean, v.candidate_id
  ) vg
  JOIN candidates c ON c.id = vg.candidate_id;

  -- Demografi & Partisipasi per Gender
  SELECT json_agg(
    json_build_object(
      'gender', pg.gender_clean,
      'voted', pg.voted,
      'not_voted', pg.not_voted,
      'total', pg.total,
      'pct', CASE WHEN pg.total > 0 THEN ROUND((pg.voted::numeric / pg.total::numeric) * 100, 1) ELSE 0 END
    ) ORDER BY pg.gender_clean
  )
  INTO v_part_gender
  FROM (
    SELECT
      CASE 
        WHEN LOWER(TRIM(gender)) LIKE 'l%' THEN 'Laki-laki'
        WHEN LOWER(TRIM(gender)) LIKE 'p%' THEN 'Perempuan'
        ELSE 'Lainnya'
      END AS gender_clean,
      SUM(CASE WHEN has_voted THEN 1 ELSE 0 END) AS voted,
      SUM(CASE WHEN NOT has_voted THEN 1 ELSE 0 END) AS not_voted,
      COUNT(*) AS total
    FROM voters
    GROUP BY gender_clean
  ) pg;

  RETURN json_build_object(
    'ok', true,
    'data', json_build_object(
      'total_voters',             v_total_voters,
      'total_votes',              v_total_votes,
      'candidates_votes',         COALESCE(v_cand_votes,   '[]'::json),
      'participation_by_class',   COALESCE(v_part_class,   '[]'::json),
      'votes_by_class_candidate', COALESCE(v_votes_class,  '[]'::json),
      'votes_per_hour',           COALESCE(v_trend,        '[]'::json),
      'votes_by_gender_candidate',COALESCE(v_votes_gender, '[]'::json),
      'participation_by_gender',  COALESCE(v_part_gender,  '[]'::json)
    )
  );
END;
$$;

-- =====================================================================
-- SELESAI
-- Catatan deployment:
--   1. Pastikan ekstensi pgcrypto aktif (Supabase sudah mengaktifkannya)
--   2. Isi js/config.js dengan SUPABASE_URL dan SUPABASE_ANON_KEY
--   3. Untuk mengubah sandi admin:
--      UPDATE election_config
--      SET admin_password = crypt('sandiBaruAnda', gen_salt('bf'))
--      WHERE id = 1;
-- =====================================================================
