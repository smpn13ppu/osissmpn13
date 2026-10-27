-- =====================================================================
-- PERBAIKAN DATABASE: admin_reset_votes & admin_analytics
-- 1. Mengatasi error "DELETE requires a WHERE clause" saat reset suara
-- 2. Mengatasi error "aggregate function calls cannot be nested" di analitik
-- 
-- Jalankan seluruh isi script ini di Supabase SQL Editor:
-- https://supabase.com/dashboard/project/tvbqwlnnzoybqxhmpooh
-- =====================================================================

-- ── 1. admin_reset_votes (Perbaikan Tombol Reset Suara) ───────────────
CREATE OR REPLACE FUNCTION admin_reset_votes(p_token uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF NOT _is_admin(p_token) THEN
    RETURN json_build_object('ok', false, 'error', 'Sesi tidak valid.');
  END IF;

  -- Memakai WHERE id IS NOT NULL agar lolos proteksi safeupdate Supabase
  DELETE FROM votes WHERE id IS NOT NULL;
  UPDATE voters SET has_voted = false, voted_at = NULL WHERE id IS NOT NULL;

  RETURN json_build_object('ok', true, 'data', json_build_object('message', 'Semua suara telah direset.'));
END;
$$;


-- ── 2. admin_delete_voters_bulk (Hapus Banyak Pemilih Sekaligus) ──────
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


-- ── 3. admin_analytics (Perbaikan Sebaran Suara, Kelas & Demografi Gender) ──
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

  -- Total pemilih dan total suara masuk
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
    SELECT candidate_id, COUNT(*) AS cnt 
    FROM votes 
    GROUP BY candidate_id
  ) v ON v.candidate_id = c.id;

  -- Partisipasi per kelas (sudah vs belum memilih)
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

  -- Suara per kelas & kandidat (sebaran paslon per kelas)
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

  -- Suara per Gender & Paslon (Berapa pemilih Laki-laki & Perempuan yang memilih tiap paslon)
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
