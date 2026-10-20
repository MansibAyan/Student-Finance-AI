-- Stage A: hardening and correctness (data integrity first).
-- PREREQUISITE: MIGRATE_ALL.sql (or ALL_IN_ONE.sql) and 09_planner_goals.sql already applied. Re-runnable.
-- Changes: supported_currencies + foreign keys (NOT VALID, so old rows are untouched); reversed_at column;
--   refunds netted against spending; frozen budget history (anchors); safer /undo; voice/large-amount confirmation;
--   explicit dates; week+month forecast; revoke anon access to bot functions.
-- Nothing is dropped. Functions replaced here are guarded (abort if they are not the versions this project created).

DO $chk$
DECLARE def text;
BEGIN
  IF to_regclass('public.transactions') IS NULL OR to_regclass('public.pending_receipts') IS NULL THEN
    RAISE EXCEPTION 'Base schema missing. Run MIGRATE_ALL.sql, then 09_planner_goals.sql.'; END IF;
  IF to_regprocedure('stage6_action(uuid,jsonb,user_settings,date)') IS NULL THEN
    RAISE EXCEPTION 'stage6_action missing. Apply 09_planner_goals.sql first.'; END IF;
  def := pg_get_functiondef(to_regprocedure('app_handle(uuid,jsonb)'));
  IF def NOT LIKE '%stage2_action%' OR def NOT LIKE '%WHEN ''undo_last'' THEN%' THEN
    RAISE EXCEPTION 'app_handle is not the version created by this project; aborting so it is not overwritten.'; END IF;
  def := pg_get_functiondef(to_regprocedure('stage6_action(uuid,jsonb,user_settings,date)'));
  IF def NOT LIKE '%goal_set%' THEN RAISE EXCEPTION 'stage6_action was modified; aborting.'; END IF;
  def := pg_get_functiondef(to_regprocedure('stage3_action(uuid,jsonb,user_settings,date)'));
  IF def NOT LIKE '%month_plan%' THEN RAISE EXCEPTION 'stage3_action was modified; aborting.'; END IF;
END $chk$;

-- ---------- supported currencies (foreign keys; NOT VALID so existing rows are not rejected) ----------
CREATE TABLE IF NOT EXISTS supported_currencies (
  code char(3) PRIMARY KEY CHECK (code ~ '^[A-Z]{3}$'),
  name text NOT NULL,
  active boolean NOT NULL DEFAULT true
);
INSERT INTO supported_currencies(code, name) VALUES
 ('BDT','Bangladeshi taka'),('USD','US dollar'),('EUR','Euro'),('GBP','Pound sterling'),('INR','Indian rupee'),
 ('AUD','Australian dollar'),('CAD','Canadian dollar'),('SGD','Singapore dollar'),('MYR','Malaysian ringgit'),('JPY','Japanese yen'),
 ('CNY','Chinese yuan'),('AED','UAE dirham'),('SAR','Saudi riyal'),('QAR','Qatari riyal'),('KWD','Kuwaiti dinar'),
 ('NZD','New Zealand dollar'),('CHF','Swiss franc'),('HKD','Hong Kong dollar'),('THB','Thai baht'),('KRW','South Korean won'),
 ('TRY','Turkish lira'),('PKR','Pakistani rupee'),('LKR','Sri Lankan rupee'),('NPR','Nepalese rupee')
ON CONFLICT (code) DO NOTHING;
ALTER TABLE supported_currencies ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON supported_currencies FROM anon, authenticated;
DO $fk$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES ('transactions','currency'),('debts','currency'),('semester_obligations','currency'),
      ('payment_method_quotes','from_currency'),('payment_method_quotes','to_currency'),('savings_goals','currency'),
      ('budgets','currency'),('recurring_transactions','currency'),('financial_accounts','currency'),('user_settings','default_currency')) v(t, c)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = r.t || '_' || r.c || '_supported_fk') THEN
      EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES supported_currencies(code) NOT VALID', r.t, r.t || '_' || r.c || '_supported_fk', r.c);
    END IF;
  END LOOP;
END $fk$;

ALTER TABLE transactions ADD COLUMN IF NOT EXISTS reversed_at timestamptz;

CREATE OR REPLACE FUNCTION net_spend(p_user uuid, p_from date, p_to date, p_cur text, p_cat text DEFAULT NULL) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT GREATEST(0, COALESCE(SUM(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END), 0))
    FROM transactions t
   WHERE t.user_id = p_user AND t.type IN ('expense','refund') AND t.status = 'confirmed'
     AND t.currency = p_cur AND t.tx_date BETWEEN p_from AND p_to AND (p_cat IS NULL OR t.category = p_cat)
$$;

-- Known money commitments up to a date, in one currency: borrowed debts, unpaid semester fees, recurring expenses.
CREATE OR REPLACE FUNCTION known_due(p_user uuid, p_until date, p_cur text) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT sum(d.remaining) FROM debts d WHERE d.user_id = p_user AND d.status = 'open' AND d.direction = 'borrowed'
                     AND d.currency = p_cur AND d.due_date IS NOT NULL AND d.due_date <= p_until), 0)
       + COALESCE((SELECT sum(o.outstanding) FROM semester_obligations o WHERE o.user_id = p_user AND o.status <> 'paid'
                     AND o.currency = p_cur AND o.due_date <= p_until), 0)
       + COALESCE((SELECT sum(r.amount * CASE WHEN r.next_due > p_until THEN 0
                                             WHEN r.frequency = 'weekly' THEN floor((p_until - r.next_due) / 7.0) + 1 ELSE 1 END)
                     FROM recurring_transactions r WHERE r.user_id = p_user AND r.active AND r.type = 'expense' AND r.currency = p_cur), 0)
$$;

CREATE OR REPLACE FUNCTION budget_status(p_user uuid, p_day date DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s user_settings%ROWTYPE; a record;
  v_today date; v_cr date; d date; allowed numeric; spent numeric; nxt numeric; consec int := 0; v_month numeric;
BEGIN
  SELECT * INTO s FROM user_settings WHERE user_id = p_user;
  v_today := COALESCE(p_day, user_today(p_user));
  SELECT (u.created_at AT TIME ZONE s.timezone)::date INTO v_cr FROM users u WHERE u.id = p_user;
  -- start from the latest anchor (a day when the budget was set), otherwise from account start
  SELECT h.day, h.allowed_budget INTO a FROM daily_budget_history h
   WHERE h.user_id = p_user AND h.override_note IS NOT NULL AND h.day <= v_today ORDER BY h.day DESC LIMIT 1;
  IF a.day IS NOT NULL THEN d := a.day; allowed := a.allowed_budget;
  ELSE d := LEAST(v_cr, v_today); allowed := s.daily_budget; END IF;
  IF v_today - d > 365 THEN d := v_today - 365; END IF;
  LOOP
    spent := net_spend(p_user, d, d, s.default_currency::text);
    IF spent > allowed THEN consec := consec + 1; ELSE consec := 0; END IF;
    nxt := GREATEST(s.budget_floor, allowed - GREATEST(0, spent - allowed));
    EXIT WHEN d >= v_today;
    allowed := nxt; d := d + 1;
  END LOOP;

  INSERT INTO daily_budget_history(user_id, day, original_budget, allowed_budget, actual_spent, overspend, next_day_budget, consecutive_overspend_days, review_required)
  VALUES (p_user, v_today, s.daily_budget, allowed, spent, GREATEST(0, spent - allowed), nxt, consec, consec > s.max_consecutive_overspend)
  ON CONFLICT (user_id, day) DO UPDATE SET
    original_budget = EXCLUDED.original_budget, allowed_budget = EXCLUDED.allowed_budget, actual_spent = EXCLUDED.actual_spent,
    overspend = EXCLUDED.overspend, next_day_budget = EXCLUDED.next_day_budget,
    consecutive_overspend_days = EXCLUDED.consecutive_overspend_days, review_required = EXCLUDED.review_required, computed_at = now();

  v_month := net_spend(p_user, v_today - (EXTRACT(day FROM v_today)::int - 1), v_today, s.default_currency::text);
  RETURN jsonb_build_object(
    'day', v_today::text, 'currency', s.default_currency, 'timezone', s.timezone,
    'original', s.daily_budget::text, 'allowed', allowed::text, 'spent', spent::text,
    'remaining', GREATEST(0, allowed - spent)::text, 'overspend', GREATEST(0, spent - allowed)::text,
    'pct_used', CASE WHEN allowed > 0 THEN round(spent / allowed * 100, 1)::text END,
    'next_day', nxt::text, 'consecutive_overspend_days', consec, 'review_required', consec > s.max_consecutive_overspend,
    'monthly_budget', s.monthly_budget::text, 'month_spent', v_month::text,
    'monthly_remaining', CASE WHEN s.monthly_budget IS NOT NULL THEN (s.monthly_budget - v_month)::text END,
    'month_pct', CASE WHEN s.monthly_budget > 0 THEN round(v_month / s.monthly_budget * 100, 1)::text END);
END $$;

CREATE OR REPLACE FUNCTION medical_remaining(p_user uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT GREATEST(0, s.medical_budget - net_spend(p_user, user_today(p_user) - (EXTRACT(day FROM user_today(p_user))::int - 1),
                                                   user_today(p_user), s.default_currency::text, 'healthcare'))
    FROM user_settings s WHERE s.user_id = p_user
$$;

CREATE OR REPLACE FUNCTION forecast_calc(p_user uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s user_settings; v_today date; v_ms date; v_me date; v_ws date; v_we date; v_first date; v_start date; v_win int;
  v_left int; v_wleft int; v_sum numeric; v_sd numeric; v_avg numeric; v_bal numeric; v_month numeric; v_week numeric;
  v_known numeric; v_proj numeric; v_pbal numeric; v_low numeric; v_high numeric; v_conf text; v_wproj numeric; v_cur text;
BEGIN
  SELECT * INTO s FROM user_settings WHERE user_id = p_user;
  v_cur := s.default_currency::text;
  v_today := user_today(p_user);
  v_ms := v_today - (EXTRACT(day FROM v_today)::int - 1);
  v_me := (v_ms + interval '1 month')::date - 1;
  v_ws := v_today - (EXTRACT(isodow FROM v_today)::int - 1);   -- weeks run Monday to Sunday
  v_we := v_ws + 6;
  SELECT min(t.tx_date) INTO v_first FROM transactions t
   WHERE t.user_id = p_user AND t.type IN ('expense','refund') AND t.status = 'confirmed' AND t.currency = s.default_currency;
  v_start := CASE WHEN v_first IS NULL THEN v_today ELSE GREATEST(v_first, v_today - 29) END;
  v_win := v_today - v_start + 1;
  SELECT COALESCE(sum(d.amt), 0), COALESCE(stddev_samp(d.amt), 0) INTO v_sum, v_sd FROM (
    SELECT g::date AS day, net_spend(p_user, g::date, g::date, v_cur) AS amt
      FROM generate_series(v_start::timestamp, v_today::timestamp, interval '1 day') g) d;
  v_avg := v_sum / v_win;
  v_bal := COALESCE((ledger_balance(p_user)->>v_cur)::numeric, 0);
  v_month := net_spend(p_user, v_ms, v_today, v_cur);
  v_week := net_spend(p_user, v_ws, v_today, v_cur);
  v_left := v_me - v_today; v_wleft := v_we - v_today;
  v_known := known_due(p_user, v_me, v_cur);
  v_proj := round(v_avg * v_left, 2); v_wproj := round(v_avg * v_wleft, 2);
  v_pbal := round(v_bal - v_proj - v_known, 2);
  IF v_win >= 7 THEN
    v_high := round((v_avg + v_sd) * v_left, 2); v_low := round(GREATEST(0, v_avg - v_sd) * v_left, 2);
  END IF;
  v_conf := CASE WHEN v_first IS NULL THEN 'none (no spending recorded yet)'
                 WHEN v_win < 7 THEN 'low (under 7 days of history)' WHEN v_win < 21 THEN 'medium' ELSE 'higher (3+ weeks of history)' END;
  RETURN jsonb_build_object('currency', v_cur, 'timezone', s.timezone, 'balance', round(v_bal, 2)::text,
    'month_spent', round(v_month, 2)::text, 'day_of_month', EXTRACT(day FROM v_today)::int,
    'window_days', v_win, 'avg_daily', round(v_avg, 2)::text,
    'sd_daily', CASE WHEN v_win >= 7 THEN round(v_sd, 2)::text END,
    'days_left', v_left, 'proj_spend', v_proj::text, 'proj_month_total', round(v_month + v_proj, 2)::text,
    'week_start', v_ws::text, 'week_end', v_we::text, 'week_days_left', v_wleft, 'week_spent', round(v_week, 2)::text,
    'week_proj_spend', v_wproj::text, 'week_total', round(v_week + v_wproj, 2)::text,
    'known_due', round(v_known, 2)::text, 'proj_balance', v_pbal::text,
    'range_low', CASE WHEN v_win >= 7 THEN round(v_bal - v_high - v_known, 2)::text END,
    'range_high', CASE WHEN v_win >= 7 THEN round(v_bal - v_low - v_known, 2)::text END,
    'monthly_budget', s.monthly_budget::text,
    'proj_vs_budget_pct', CASE WHEN s.monthly_budget > 0 THEN round((v_month + v_proj) / s.monthly_budget * 100, 1)::text END,
    'confidence', v_conf,
    'method', 'Recorded spending (net of refunds) is separate from projected spending. Projection = average daily net spending over the last ' || v_win || ' day(s), including today so far, times the days left. Range = +/- 1 standard deviation (only with 7+ days of data).',
    'note', 'Future income is not included; only money you recorded counts. Spending can change.');
END $$;

CREATE OR REPLACE FUNCTION stage7_action(p_user uuid, p_action jsonb, s user_settings, v_today date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_act text := p_action->>'action'; v_idem text := p_action->>'idem'; v_res jsonb := '{}'::jsonb;
  v_st jsonb; v_pay jsonb; v_kind text; v_inner jsonb; v_new jsonb; v_txs jsonb; v_sum text; v_n int;
BEGIN
  CASE v_act
  WHEN 'voice_stage' THEN
    v_st := p_action->'staged';
    IF v_st IS NULL OR jsonb_typeof(v_st) <> 'object' OR (v_st->>'action') NOT IN
       ('record','set_balance','create_debt','repay_debt','semester_paid','create_semester','set_daily_budget','set_monthly_budget','set_medical_budget','undo_last','add_quote') THEN
      RAISE EXCEPTION 'this kind of request cannot be staged';
    END IF;
    IF v_st->>'action' = 'record' THEN   -- freeze relative dates so a later confirmation records the right day
      SELECT jsonb_agg((x - 'days_ago') || jsonb_build_object('date',
               COALESCE(NULLIF(x->>'date',''), (v_today - COALESCE((x->>'days_ago')::int, 0))::text))) INTO v_txs
        FROM jsonb_array_elements(v_st->'transactions') x;
      v_st := jsonb_set(v_st, '{transactions}', COALESCE(v_txs, '[]'::jsonb));
      SELECT string_agg(COALESCE(x->>'type','?') || ' ' || COALESCE(x->>'amount','?') || ' ' || COALESCE(NULLIF(x->>'currency',''), s.default_currency::text)
                        || ' (' || COALESCE(x->>'category','other') || ', ' || COALESCE(x->>'date','') || ')', '; ') INTO v_sum
        FROM jsonb_array_elements(v_st->'transactions') x;
    ELSE
      v_sum := (v_st->>'action') || COALESCE(' ' || NULLIF(v_st->>'amount',''), '') || COALESCE(' ' || NULLIF(v_st->>'currency',''), '')
               || COALESCE(' ' || NULLIF(v_st->>'counterparty',''), '');
    END IF;
    DELETE FROM pending_receipts WHERE created_at < now() - interval '1 day';
    INSERT INTO pending_receipts(user_id, payload, created_at) VALUES (p_user, jsonb_build_object('kind','voice','action', v_st), now())
    ON CONFLICT (user_id) DO UPDATE SET payload = EXCLUDED.payload, created_at = now();
    v_res := jsonb_build_object('pending', jsonb_build_object('summary', v_sum, 'source', COALESCE(p_action->>'source', 'voice')));

  WHEN 'confirm_pending' THEN
    IF v_idem IS NULL THEN RAISE EXCEPTION 'missing idempotency key'; END IF;
    SELECT r.payload INTO v_pay FROM pending_receipts r WHERE r.user_id = p_user AND r.created_at > now() - interval '1 day' FOR UPDATE;
    IF v_pay IS NULL THEN RAISE EXCEPTION 'nothing is waiting for confirmation'; END IF;
    v_kind := COALESCE(v_pay->>'kind', 'receipt');
    IF v_kind = 'delete' THEN RAISE EXCEPTION 'to delete your data send /deleteme confirm'; END IF;
    IF v_kind = 'voice' THEN
      v_new := (v_pay->'action') || jsonb_build_object('idem', v_idem);
      v_inner := app_handle(p_user, v_new);
      IF COALESCE((v_inner->>'ok')::boolean, false) IS NOT TRUE THEN RAISE EXCEPTION '%', COALESCE(v_inner->>'error', 'could not save'); END IF;
      DELETE FROM pending_receipts WHERE user_id = p_user;
      v_res := (v_inner - 'ok' - 'snapshot');
    ELSE
      v_res := stage5_action(p_user, jsonb_build_object('action', 'receipt_confirm', 'idem', v_idem), s, v_today);
    END IF;

  WHEN 'cancel_pending' THEN
    DELETE FROM pending_receipts WHERE user_id = p_user;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_res := jsonb_build_object('message', CASE WHEN v_n > 0 THEN 'Cancelled. Nothing was saved.' ELSE 'Nothing was waiting for confirmation.' END);
  ELSE
    v_res := stage8_action(p_user, p_action, s, v_today);
  END CASE;
  RETURN v_res;
END $$;

-- Stubs, replaced by Part B and Part C
CREATE OR REPLACE FUNCTION stage8_action(p_user uuid, p_action jsonb, s user_settings, v_today date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN RAISE EXCEPTION 'unsupported action'; END $$;

-- ---------- alert helper (stub here; Part B replaces it) ----------
CREATE OR REPLACE FUNCTION budget_alerts_for_user(p_user uuid) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$ SELECT '[]'::jsonb $$;

-- ---------- re-define stage chain: stage6 now delegates to stage7 ----------
CREATE OR REPLACE FUNCTION app_handle(p_user uuid, p_action jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_act text := p_action->>'action';
  v_idem text := p_action->>'idem';
  s user_settings%ROWTYPE;
  v_today date; v_acct uuid; v_from date;
  e jsonb; i int := 0;
  v_amt numeric; v_type text; v_cur text; v_cat text; v_days int;
  v_id uuid; v_saved jsonb := '[]'::jsonb; v_dups int := 0;
  v_res jsonb := '{}'::jsonb; v_rows jsonb; v_rows2 jsonb;
  v_row record; v_cp text; v_dir text; v_due date;
BEGIN
  PERFORM 1 FROM users WHERE id = p_user AND deleted_at IS NULL FOR UPDATE;  -- serialize per user
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown user'; END IF;
  SELECT * INTO s FROM user_settings WHERE user_id = p_user;
  v_today := user_today(p_user);
  SELECT id INTO v_acct FROM financial_accounts WHERE user_id = p_user AND is_default LIMIT 1;

  CASE v_act
  WHEN 'record' THEN
    IF v_idem IS NULL THEN RAISE EXCEPTION 'missing idempotency key'; END IF;
    IF jsonb_typeof(p_action->'transactions') <> 'array'
       OR jsonb_array_length(p_action->'transactions') NOT BETWEEN 1 AND 10 THEN
      RAISE EXCEPTION 'provide 1 to 10 transactions';
    END IF;
    FOR e IN SELECT x FROM jsonb_array_elements(p_action->'transactions') AS x LOOP
      i := i + 1;
      v_type := e->>'type';
      IF v_type IS NULL OR v_type NOT IN ('income','expense','refund') THEN RAISE EXCEPTION 'invalid transaction type'; END IF;
      v_amt := (e->>'amount')::numeric;
      IF v_amt IS NULL OR v_amt <= 0 OR v_amt > 10000000 THEN RAISE EXCEPTION 'amount must be between 0 and 10,000,000'; END IF;
      v_cur := upper(COALESCE(NULLIF(e->>'currency',''), s.default_currency));
      IF v_cur !~ '^[A-Z]{3}$' THEN RAISE EXCEPTION 'invalid currency'; END IF;
      v_cat := COALESCE(NULLIF(e->>'category',''), 'other');
      IF NOT EXISTS (SELECT 1 FROM transaction_categories c WHERE c.name = v_cat AND c.kind <> 'loan') THEN v_cat := 'other'; END IF;
      IF v_type = 'income' AND v_cat <> 'other' AND NOT EXISTS (SELECT 1 FROM transaction_categories c WHERE c.name = v_cat AND c.kind = 'income') THEN v_cat := 'other'; END IF;
      IF v_type <> 'income' AND EXISTS (SELECT 1 FROM transaction_categories c WHERE c.name = v_cat AND c.kind = 'income') THEN v_cat := 'other'; END IF;
      IF NULLIF(e->>'date', '') IS NOT NULL THEN
        BEGIN v_days := v_today - (e->>'date')::date; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'invalid date, use YYYY-MM-DD'; END;
      ELSE
        v_days := COALESCE((e->>'days_ago')::int, 0);
      END IF;
      IF v_days NOT BETWEEN 0 AND 365 THEN RAISE EXCEPTION 'date must be within the last 365 days and not in the future'; END IF;
      v_id := NULL;
      INSERT INTO transactions(user_id, account_id, type, amount, currency, category, description,
                               tx_date, source, status, idempotency_key)
      VALUES (p_user, v_acct, v_type, v_amt, v_cur, v_cat, left(COALESCE(e->>'description',''), 200),
              v_today - v_days, 'manual', 'confirmed', v_idem || ':' || i)
      ON CONFLICT (user_id, idempotency_key) DO NOTHING
      RETURNING id INTO v_id;
      IF v_id IS NULL THEN
        v_dups := v_dups + 1;
      ELSE
        v_saved := v_saved || jsonb_build_array(jsonb_build_object(
          'type', v_type, 'amount', v_amt::text, 'currency', v_cur, 'category', v_cat,
          'date', (v_today - v_days)::text,
          'essential', COALESCE((SELECT c.is_essential FROM transaction_categories c WHERE c.name = v_cat), false)));
        INSERT INTO audit_logs(user_id, action, entity, entity_id, detail)
        VALUES (p_user, 'create', 'transaction', v_id,
                jsonb_build_object('type', v_type, 'amount', v_amt, 'currency', v_cur));
      END IF;
    END LOOP;
    v_res := jsonb_build_object('saved', v_saved, 'duplicates', v_dups);

  WHEN 'snapshot' THEN
    NULL;

  WHEN 'summary' THEN
    v_from := CASE p_action->>'period'
      WHEN 'today' THEN v_today WHEN 'week' THEN v_today - 6 WHEN '30d' THEN v_today - 29
      ELSE v_today - (EXTRACT(day FROM v_today)::int - 1) END;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('category', x.category, 'currency', x.currency, 'total', x.total::text) ORDER BY x.total DESC), '[]'::jsonb) INTO v_rows
    FROM (SELECT t.category, t.currency, GREATEST(0, SUM(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END)) AS total
            FROM transactions t WHERE t.user_id = p_user AND t.type IN ('expense','refund') AND t.status = 'confirmed'
             AND t.tx_date BETWEEN v_from AND v_today GROUP BY t.category, t.currency
           HAVING SUM(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END) > 0) x;
    SELECT COALESCE(jsonb_agg(jsonb_build_object('currency', x.currency, 'total', x.total::text)), '[]'::jsonb) INTO v_rows2
    FROM (SELECT t.currency, SUM(t.amount) AS total FROM transactions t
           WHERE t.user_id = p_user AND t.type = 'income' AND t.status = 'confirmed'
             AND t.tx_date BETWEEN v_from AND v_today GROUP BY t.currency) x;
    v_res := jsonb_build_object('period', COALESCE(p_action->>'period','month'), 'from', v_from::text,
                                'expenses', v_rows, 'income', v_rows2, 'note', 'Expenses are net of refunds; loans and balance adjustments are not income or spending.');

  WHEN 'set_daily_budget' THEN
    v_amt := (p_action->>'amount')::numeric;
    IF v_amt IS NULL OR v_amt < 0 OR v_amt > 1000000 THEN RAISE EXCEPTION 'invalid budget amount'; END IF;
    -- keep history: anchor the OLD budget at account start (once), then anchor the NEW budget from today onward
    INSERT INTO daily_budget_history(user_id, day, original_budget, allowed_budget, actual_spent, overspend, next_day_budget,
           consecutive_overspend_days, review_required, override_note)
    SELECT p_user, LEAST((u.created_at AT TIME ZONE s.timezone)::date, v_today), s.daily_budget, s.daily_budget, 0, 0, s.daily_budget, 0, false, 'initial'
      FROM users u WHERE u.id = p_user
       AND NOT EXISTS (SELECT 1 FROM daily_budget_history h WHERE h.user_id = p_user AND h.override_note IS NOT NULL)
    ON CONFLICT (user_id, day) DO UPDATE SET override_note = 'initial', original_budget = EXCLUDED.original_budget, allowed_budget = EXCLUDED.allowed_budget;
    INSERT INTO daily_budget_history(user_id, day, original_budget, allowed_budget, actual_spent, overspend, next_day_budget,
           consecutive_overspend_days, review_required, override_note)
    VALUES (p_user, v_today, v_amt, v_amt, 0, 0, v_amt, 0, false, 'budget set')
    ON CONFLICT (user_id, day) DO UPDATE SET original_budget = v_amt, allowed_budget = v_amt, override_note = 'budget set';
    UPDATE user_settings SET daily_budget = v_amt, updated_at = now() WHERE user_id = p_user;
    INSERT INTO audit_logs(user_id, action, entity, detail)
    VALUES (p_user, 'update', 'daily_budget', jsonb_build_object('amount', v_amt));
    v_res := jsonb_build_object('message', 'Daily budget set to ' || v_amt::text || ' ' || s.default_currency
             || ' from today. Earlier days keep the budget they had; the overspend rule restarts from today.');

  WHEN 'set_monthly_budget' THEN
    v_amt := (p_action->>'amount')::numeric;
    IF v_amt IS NULL OR v_amt < 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'invalid budget amount'; END IF;
    UPDATE user_settings SET monthly_budget = v_amt, updated_at = now() WHERE user_id = p_user;
    INSERT INTO audit_logs(user_id, action, entity, detail)
    VALUES (p_user, 'update', 'monthly_budget', jsonb_build_object('amount', v_amt));
    v_res := jsonb_build_object('message', 'Monthly budget set to ' || v_amt::text || ' ' || s.default_currency);

  WHEN 'undo_last' THEN
    SELECT t.id, t.type, t.amount, t.currency, t.category, t.tx_date INTO v_row FROM transactions t
     WHERE t.user_id = p_user AND t.status = 'confirmed' ORDER BY t.created_at DESC, t.id DESC LIMIT 1;
    IF v_row.id IS NULL THEN RAISE EXCEPTION 'nothing to undo'; END IF;
    IF v_row.type IN ('loan_received','loan_repayment','loan_given','loan_collected') THEN
      RAISE EXCEPTION 'your latest entry is a debt record (% % %); debt entries cannot be undone with /undo yet', v_row.type, v_row.amount, v_row.currency;
    END IF;
    UPDATE transactions SET status = 'reversed', reversed_at = now() WHERE id = v_row.id AND status = 'confirmed';
    INSERT INTO audit_logs(user_id, action, entity, entity_id, detail)
    VALUES (p_user, 'reverse', 'transaction', v_row.id, jsonb_build_object('type', v_row.type));
    v_res := jsonb_build_object('message', 'Reversed your latest entry: ' || v_row.type || ' ' || v_row.amount::text || ' ' || v_row.currency
                                 || ' (' || v_row.category || ', ' || v_row.tx_date::text || '). The original is kept in history as reversed.');

  WHEN 'create_debt' THEN
    IF v_idem IS NULL THEN RAISE EXCEPTION 'missing idempotency key'; END IF;
    v_dir := p_action->>'direction';
    IF v_dir IS NULL OR v_dir NOT IN ('borrowed','lent') THEN RAISE EXCEPTION 'direction must be borrowed or lent'; END IF;
    v_cp := left(trim(COALESCE(p_action->>'counterparty','')), 80);
    IF v_cp = '' THEN RAISE EXCEPTION 'who is the other person?'; END IF;
    v_amt := (p_action->>'amount')::numeric;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > 10000000 THEN RAISE EXCEPTION 'invalid amount'; END IF;
    v_cur := upper(COALESCE(NULLIF(p_action->>'currency',''), s.default_currency));
    IF v_cur !~ '^[A-Z]{3}$' THEN RAISE EXCEPTION 'invalid currency'; END IF;
    v_due := CASE WHEN p_action->>'due_in_days' IS NULL THEN NULL
                  ELSE v_today + LEAST(GREATEST((p_action->>'due_in_days')::int, 0), 3650) END;
    v_id := NULL;
    INSERT INTO transactions(user_id, account_id, type, amount, currency, category, description,
                             tx_date, source, status, idempotency_key)
    VALUES (p_user, v_acct, CASE WHEN v_dir = 'borrowed' THEN 'loan_received' ELSE 'loan_given' END,
            v_amt, v_cur, 'loan', left(v_cp, 80), v_today, 'manual', 'confirmed', v_idem || ':debt')
    ON CONFLICT (user_id, idempotency_key) DO NOTHING RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      v_res := jsonb_build_object('duplicates', 1);
    ELSE
      INSERT INTO debts(user_id, direction, counterparty, principal, remaining, currency, start_date, due_date)
      VALUES (p_user, v_dir, v_cp, v_amt, v_amt, v_cur, v_today, v_due) RETURNING id INTO v_id;
      INSERT INTO audit_logs(user_id, action, entity, entity_id, detail)
      VALUES (p_user, 'create', 'debt', v_id, jsonb_build_object('direction', v_dir, 'amount', v_amt));
      v_res := jsonb_build_object('message', CASE WHEN v_dir = 'borrowed' THEN 'Recorded: you owe ' ELSE 'Recorded: ' END
               || v_cp || CASE WHEN v_dir = 'borrowed' THEN ' ' ELSE ' owes you ' END
               || v_amt::text || ' ' || v_cur || COALESCE(', due ' || v_due::text, ''));
    END IF;

  WHEN 'repay_debt' THEN
    IF v_idem IS NULL THEN RAISE EXCEPTION 'missing idempotency key'; END IF;
    v_cp := lower(trim(COALESCE(p_action->>'counterparty','')));
    v_amt := (p_action->>'amount')::numeric;
    IF v_amt IS NULL OR v_amt <= 0 THEN RAISE EXCEPTION 'invalid amount'; END IF;
    SELECT d.id, d.remaining, d.direction, d.currency INTO v_row FROM debts d
     WHERE d.user_id = p_user AND d.status = 'open' AND lower(d.counterparty) = v_cp
     ORDER BY d.due_date NULLS LAST, d.created_at LIMIT 1 FOR UPDATE;
    IF v_row.id IS NULL THEN RAISE EXCEPTION 'no open debt found for that name'; END IF;
    IF v_amt > v_row.remaining THEN
      RAISE EXCEPTION 'amount is more than the remaining balance (%)', v_row.remaining;
    END IF;
    v_id := NULL;
    INSERT INTO debt_repayments(debt_id, user_id, amount, paid_on, idempotency_key)
    VALUES (v_row.id, p_user, v_amt, v_today, v_idem)
    ON CONFLICT (user_id, idempotency_key) DO NOTHING RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      v_res := jsonb_build_object('duplicates', 1);
    ELSE
      UPDATE debts SET remaining = remaining - v_amt,
             status = CASE WHEN remaining - v_amt = 0 THEN 'paid' ELSE 'open' END
       WHERE id = v_row.id;
      INSERT INTO transactions(user_id, account_id, type, amount, currency, category, description,
                               tx_date, source, status, idempotency_key)
      VALUES (p_user, v_acct, CASE WHEN v_row.direction = 'borrowed' THEN 'loan_repayment' ELSE 'loan_collected' END,
              v_amt, v_row.currency, 'loan', 'debt repayment', v_today, 'manual', 'confirmed', v_idem || ':rp');
      INSERT INTO audit_logs(user_id, action, entity, entity_id, detail)
      VALUES (p_user, 'create', 'debt_repayment', v_id, jsonb_build_object('amount', v_amt));
      v_res := jsonb_build_object('message', 'Repayment recorded: ' || v_amt::text || ' ' || v_row.currency
               || '. Remaining: ' || (v_row.remaining - v_amt)::text);
    END IF;

  WHEN 'list_debts' THEN
    SELECT COALESCE(jsonb_agg(jsonb_build_object('direction', d.direction, 'who', d.counterparty,
             'remaining', d.remaining::text, 'currency', d.currency, 'due', d.due_date::text,
             'overdue', d.due_date IS NOT NULL AND d.due_date < v_today) ORDER BY d.due_date NULLS LAST), '[]'::jsonb)
      INTO v_rows FROM debts d WHERE d.user_id = p_user AND d.status = 'open';
    v_res := jsonb_build_object('debts', v_rows);

  ELSE
    RAISE EXCEPTION 'unsupported action';
  END CASE;

  IF v_act = 'delete_account_confirm' THEN RETURN v_res || jsonb_build_object('ok', true); END IF;
  IF v_act = 'record' THEN v_res := v_res || jsonb_build_object('alerts', budget_alerts_for_user(p_user)); END IF;
  RETURN v_res || jsonb_build_object('ok', true, 'snapshot', finance_snapshot(p_user));
EXCEPTION
  WHEN raise_exception THEN RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
  WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid number in request');
  WHEN foreign_key_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unsupported currency or invalid reference. Supported currencies: '
           || COALESCE((SELECT string_agg(code, ', ' ORDER BY code) FROM supported_currencies WHERE active), 'none') || '. Nothing was saved.');
  WHEN OTHERS THEN RETURN jsonb_build_object('ok', false, 'error', 'internal error, nothing was changed');
END $$;

CREATE OR REPLACE FUNCTION stage3_action(p_user uuid, p_action jsonb, s user_settings, v_today date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_act text := p_action->>'action'; v_amt numeric; v_res jsonb := '{}'::jsonb;
  v_spent numeric; v_other numeric; v_income numeric; v_bal numeric; v_debts numeric; v_sem numeric;
  v_med numeric; v_free numeric; v_sug numeric; v_days int; v_rows jsonb; v_kind text; v_city text;
  v_month_start date := v_today - (EXTRACT(day FROM v_today)::int - 1);
BEGIN
  CASE v_act
  WHEN 'set_medical_budget' THEN
    v_amt := (p_action->>'amount')::numeric;
    IF v_amt IS NULL OR v_amt < 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'invalid amount'; END IF;
    UPDATE user_settings SET medical_budget = v_amt, updated_at = now() WHERE user_id = p_user;
    INSERT INTO audit_logs(user_id, action, entity, detail)
    VALUES (p_user, 'update', 'medical_budget', jsonb_build_object('amount', v_amt));
    v_res := jsonb_build_object('message', 'Monthly medical fund set to ' || v_amt::text || ' ' || s.default_currency
             || '. It is set aside before other spending in your monthly plan.');

  WHEN 'medical_status' THEN
    v_spent := net_spend(p_user, v_month_start, v_today, s.default_currency::text, 'healthcare');
    v_res := jsonb_build_object('medical', jsonb_build_object('currency', s.default_currency,
             'budget', s.medical_budget::text, 'spent', v_spent::text,
             'remaining', GREATEST(0, s.medical_budget - v_spent)::text,
             'over', GREATEST(0, v_spent - s.medical_budget)::text));

  WHEN 'month_plan' THEN
    v_income := COALESCE(NULLIF(p_action->>'income','')::numeric, (
      SELECT COALESCE(SUM(t.amount), 0) FROM transactions t
       WHERE t.user_id = p_user AND t.type = 'income' AND t.status = 'confirmed'
         AND t.currency = s.default_currency AND t.tx_date >= v_month_start));
    v_spent := net_spend(p_user, v_month_start, v_today, s.default_currency::text, 'healthcare');
    v_other := GREATEST(0, net_spend(p_user, v_month_start, v_today, s.default_currency::text) - v_spent);
    v_days := ((v_month_start + interval '1 month')::date - v_today);
    v_free := v_income - s.medical_budget - v_other;
    v_res := jsonb_build_object('month_plan', jsonb_build_object('currency', s.default_currency,
      'income', v_income::text, 'income_source', CASE WHEN NULLIF(p_action->>'income','') IS NULL THEN 'recorded this month' ELSE 'amount you stated' END,
      'medical_budget', s.medical_budget::text, 'medical_spent', v_spent::text,
      'other_spent', v_other::text, 'left_for_other', v_free::text,
      'days_left', v_days, 'per_day', (GREATEST(0, v_free) / GREATEST(1, v_days))::numeric(14,2)::text,
      'shortfall', (GREATEST(0, -v_free))::text));

  WHEN 'suggest_donation' THEN
    v_bal := COALESCE((ledger_balance(p_user)->>s.default_currency::text)::numeric, 0);
    SELECT COALESCE(SUM(d.remaining), 0) INTO v_debts FROM debts d
     WHERE d.user_id = p_user AND d.status = 'open' AND d.direction = 'borrowed' AND d.currency = s.default_currency
       AND d.due_date IS NOT NULL AND d.due_date <= v_today + 30;
    SELECT COALESCE(SUM(o.outstanding), 0) INTO v_sem FROM semester_obligations o
     WHERE o.user_id = p_user AND o.status <> 'paid' AND o.currency = s.default_currency AND o.due_date <= v_today + 30;
    v_med := medical_remaining(p_user);
    v_free := v_bal - s.emergency_reserve - v_debts - v_sem - v_med;
    v_sug := CASE WHEN v_free >= 200 THEN floor(v_free * 0.05 / 10) * 10 ELSE 0 END;
    SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v_rows FROM (
      SELECT h.org, h.title, h.details, h.city, h.phone, h.url, h.source, h.last_verified::text AS verified
        FROM health_directory h WHERE h.kind = 'donation' AND h.active
         AND (h.valid_until IS NULL OR h.valid_until >= v_today)
       ORDER BY h.last_verified DESC LIMIT 5) x;
    v_res := jsonb_build_object('donation', jsonb_build_object('currency', s.default_currency,
      'spendable', v_free::text, 'suggested', v_sug::text, 'causes', v_rows));

  WHEN 'health_list' THEN
    v_kind := p_action->>'kind';
    IF v_kind IS NULL OR v_kind NOT IN ('checkup','donation','aid') THEN RAISE EXCEPTION 'unknown list'; END IF;
    v_city := NULLIF(trim(COALESCE(p_action->>'city','')), '');
    SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v_rows FROM (
      SELECT h.org, h.title, h.price::text AS price, h.currency, h.details, h.city, h.phone, h.url,
             h.source, h.last_verified::text AS verified, h.valid_until::text AS valid_until,
             (v_today - h.last_verified) AS age_days
        FROM health_directory h
       WHERE h.kind = v_kind AND h.active AND (h.valid_until IS NULL OR h.valid_until >= v_today)
         AND (v_city IS NULL OR h.city ILIKE '%' || replace(replace(v_city, '%', ''), '_', '') || '%')
       ORDER BY h.price NULLS LAST, h.last_verified DESC LIMIT 8) x;
    v_res := jsonb_build_object('health', jsonb_build_object('kind', v_kind, 'rows', v_rows));
  ELSE
    v_res := stage4_action(p_user, p_action, s, v_today);
  END CASE;
  RETURN v_res;
END $$;

CREATE OR REPLACE FUNCTION stage6_action(p_user uuid, p_action jsonb, s user_settings, v_today date)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_act text := p_action->>'action'; v_idem text := p_action->>'idem'; v_res jsonb := '{}'::jsonb;
  v_amt numeric; v_cur text; v_name text; v_date date; v_id uuid; v_pref text; v_n int; v_fc jsonb; v_pur jsonb; v_after numeric;
  v_ms date; v_pms date; v_inc numeric; v_exp numeric; v_rows jsonb; v_over int; v_sem jsonb; v_key text; v_saved numeric; v_target numeric;
BEGIN
  CASE v_act
  WHEN 'forecast' THEN
    v_res := jsonb_build_object('forecast', forecast_calc(p_user));

  WHEN 'whatif' THEN   -- SIMULATION ONLY: nothing is inserted
    v_amt := (p_action->>'amount')::numeric;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > 100000000 THEN RAISE EXCEPTION 'invalid amount'; END IF;
    v_cur := upper(COALESCE(NULLIF(p_action->>'currency',''), s.default_currency));
    IF v_cur !~ '^[A-Z]{3}$' THEN RAISE EXCEPTION 'invalid currency'; END IF;
    v_pur := stage2_action(p_user, jsonb_build_object('action','evaluate_purchase','amount',v_amt::text,'currency',v_cur), s, v_today)->'purchase';
    v_fc := forecast_calc(p_user);
    v_after := CASE WHEN v_cur = s.default_currency THEN (v_fc->>'proj_balance')::numeric - v_amt END;
    v_res := jsonb_build_object('whatif', jsonb_build_object('simulation', true,
      'label', left(regexp_replace(COALESCE(p_action->>'label',''), '[\r\n]+', ' ', 'g'), 60),
      'amount', v_amt::text, 'currency', v_cur, 'purchase', v_pur,
      'balance_after', CASE WHEN v_cur = s.default_currency THEN ((v_fc->>'balance')::numeric - v_amt)::text END,
      'forecast_before', CASE WHEN v_cur = s.default_currency THEN v_fc->>'proj_balance' END,
      'forecast_after', v_after::text, 'forecast_currency', s.default_currency));

  WHEN 'coach' THEN
    v_ms := v_today - (EXTRACT(day FROM v_today)::int - 1);
    v_pms := (v_ms - interval '1 month')::date;
    SELECT COALESCE(sum(t.amount), 0) INTO v_inc FROM transactions t
     WHERE t.user_id = p_user AND t.type = 'income' AND t.status = 'confirmed' AND t.currency = s.default_currency
       AND t.tx_date BETWEEN v_ms AND v_today;
    v_exp := net_spend(p_user, v_ms, v_today, s.default_currency::text);
    WITH cur AS (
      SELECT t.category, GREATEST(0, sum(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END)) AS tot FROM transactions t
       WHERE t.user_id = p_user AND t.type IN ('expense','refund') AND t.status = 'confirmed' AND t.currency = s.default_currency
         AND t.tx_date BETWEEN v_ms AND v_today GROUP BY t.category
       HAVING sum(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END) > 0 ORDER BY 2 DESC LIMIT 3),
    prev AS (
      SELECT t.category, GREATEST(0, sum(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END)) AS tot FROM transactions t
       WHERE t.user_id = p_user AND t.type IN ('expense','refund') AND t.status = 'confirmed' AND t.currency = s.default_currency
         AND t.tx_date BETWEEN v_pms AND v_pms + (v_today - v_ms) GROUP BY t.category)
    SELECT COALESCE(jsonb_agg(jsonb_build_object('category', c.category, 'total', c.tot::text,
             'share', round(c.tot / NULLIF(v_exp, 0) * 100, 0)::text, 'prev', COALESCE(p.tot, 0)::text,
             'essential', COALESCE((SELECT k.is_essential FROM transaction_categories k WHERE k.name = c.category), false))
             ORDER BY c.tot DESC), '[]'::jsonb) INTO v_rows
      FROM cur c LEFT JOIN prev p ON p.category = c.category;
    SELECT count(*) INTO v_over FROM (
      SELECT t.tx_date FROM transactions t WHERE t.user_id = p_user AND t.type IN ('expense','refund') AND t.status = 'confirmed'
         AND t.currency = s.default_currency AND t.tx_date > v_today - 14
       GROUP BY t.tx_date HAVING sum(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END) > s.daily_budget) x;
    v_sem := COALESCE(stage2_action(p_user, '{"action":"semester_plan"}'::jsonb, s, v_today)->'plan', '[]'::jsonb);
    v_res := jsonb_build_object('coach', jsonb_build_object('currency', s.default_currency,
      'income_mtd', v_inc::text, 'expense_mtd', v_exp::text,
      'savings_rate', CASE WHEN v_inc > 0 THEN round((v_inc - v_exp) / v_inc * 100, 1)::text END,
      'top_categories', v_rows, 'days_over_budget_14', v_over, 'daily_budget', s.daily_budget::text,
      'medical_budget', s.medical_budget::text, 'medical_remaining', medical_remaining(p_user)::text,
      'semester', v_sem, 'goals', goals_json(p_user, v_today)));

  WHEN 'goal_set' THEN
    IF v_idem IS NULL THEN RAISE EXCEPTION 'missing idempotency key'; END IF;
    v_name := trim(regexp_replace(COALESCE(p_action->>'name',''), '[\r\n\t]+', ' ', 'g'));
    IF char_length(v_name) < 2 OR char_length(v_name) > 60 THEN RAISE EXCEPTION 'goal name must be 2 to 60 characters'; END IF;
    v_amt := (p_action->>'target')::numeric;
    IF v_amt IS NULL OR v_amt <= 0 OR v_amt > 1000000000 THEN RAISE EXCEPTION 'target must be between 0 and 1,000,000,000'; END IF;
    v_cur := upper(COALESCE(NULLIF(p_action->>'currency',''), s.default_currency));
    IF v_cur !~ '^[A-Z]{3}$' THEN RAISE EXCEPTION 'invalid currency'; END IF;
    BEGIN v_date := (p_action->>'target_date')::date; EXCEPTION WHEN OTHERS THEN RAISE EXCEPTION 'invalid date, use YYYY-MM-DD'; END;
    IF v_date IS NULL OR v_date < v_today OR v_date > v_today + 7300 THEN RAISE EXCEPTION 'deadline must be today or later, within 20 years'; END IF;
    SELECT count(*) INTO v_n FROM savings_goals g WHERE g.user_id = p_user;
    IF v_n >= 20 THEN RAISE EXCEPTION 'you already have 20 goals; delete one first'; END IF;
    v_id := NULL;
    INSERT INTO savings_goals(user_id, name, target_amount, currency, target_date, idempotency_key)
    VALUES (p_user, v_name, v_amt, v_cur, v_date, v_idem) ON CONFLICT (user_id, idempotency_key) DO NOTHING RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      v_res := jsonb_build_object('duplicates', 1);
    ELSE
      INSERT INTO audit_logs(user_id, action, entity, entity_id, detail)
      VALUES (p_user, 'create', 'savings_goal', v_id, jsonb_build_object('target', v_amt, 'currency', v_cur));
      v_res := jsonb_build_object('message', 'Goal saved: ' || v_name || ', ' || v_amt::text || ' ' || v_cur || ' by ' || v_date::text
               || '. Its id is ' || left(v_id::text, 8) || ' (use it for /goal save and /goal delete).', 'goals', goals_json(p_user, v_today));
    END IF;

  WHEN 'goal_list' THEN
    v_res := jsonb_build_object('goals', goals_json(p_user, v_today));

  WHEN 'goal_delete', 'goal_save' THEN
    v_pref := lower(COALESCE(p_action->>'id', ''));
    IF v_pref !~ '^[0-9a-f-]{6,36}$' THEN RAISE EXCEPTION 'give the goal id from /goal list (at least 6 characters)'; END IF;
    SELECT count(*) INTO v_n FROM savings_goals g WHERE g.user_id = p_user AND g.id::text LIKE v_pref || '%';
    IF v_n = 0 THEN RAISE EXCEPTION 'no goal of yours matches that id'; END IF;
    IF v_n > 1 THEN RAISE EXCEPTION 'that id matches more than one goal; type more characters'; END IF;
    SELECT g.id, g.name, g.saved_amount, g.target_amount INTO v_id, v_name, v_saved, v_target
      FROM savings_goals g WHERE g.user_id = p_user AND g.id::text LIKE v_pref || '%';
    IF v_act = 'goal_delete' THEN
      DELETE FROM savings_goals WHERE id = v_id AND user_id = p_user;
      INSERT INTO audit_logs(user_id, action, entity, entity_id, detail) VALUES (p_user, 'delete', 'savings_goal', v_id, '{}'::jsonb);
      v_res := jsonb_build_object('message', 'Goal deleted: ' || v_name, 'goals', goals_json(p_user, v_today));
    ELSE
      IF v_idem IS NULL THEN RAISE EXCEPTION 'missing idempotency key'; END IF;
      v_amt := (p_action->>'amount')::numeric;
      IF v_amt IS NULL OR v_amt <= 0 OR v_amt > 1000000000 THEN RAISE EXCEPTION 'invalid amount'; END IF;
      IF v_saved + v_amt > v_target THEN RAISE EXCEPTION 'that would go over the target (remaining %)', (v_target - v_saved); END IF;
      v_key := v_idem || ':goalsave';
      INSERT INTO processed_events(event_id, source) VALUES (v_key, 'app') ON CONFLICT DO NOTHING RETURNING event_id INTO v_key;
      IF v_key IS NULL THEN
        v_res := jsonb_build_object('duplicates', 1);
      ELSE
        UPDATE savings_goals SET saved_amount = saved_amount + v_amt WHERE id = v_id AND user_id = p_user;
        INSERT INTO audit_logs(user_id, action, entity, entity_id, detail) VALUES (p_user, 'update', 'savings_goal', v_id, jsonb_build_object('added', v_amt));
        v_res := jsonb_build_object('message', 'Added ' || v_amt::text || ' to goal "' || v_name || '". This tracks your own earmark only; it does not move money in your ledger.',
                 'goals', goals_json(p_user, v_today));
      END IF;
    END IF;
  ELSE
    v_res := stage7_action(p_user, p_action, s, v_today);
  END CASE;
  RETURN v_res;
END $$;

-- ---------- least privilege: only service_role may run bot functions ----------
DO $rv$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = ANY (ARRAY[
      'app_handle','ensure_user','finance_snapshot','budget_status','ledger_balance','user_today','claim_event','due_daily_summaries',
      'mark_notification','stage2_action','stage3_action','stage4_action','stage5_action','stage6_action','stage7_action','stage8_action','stage9_action',
      'forecast_calc','goals_json','medical_remaining','health_support_handle','add_price_report','search_prices','net_spend','known_due',
      'budget_alerts_for_user','budget_overview','report_data','due_notifications'])
  LOOP
    EXECUTE 'REVOKE EXECUTE ON FUNCTION ' || r.sig || ' FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION ' || r.sig || ' TO service_role';
  END LOOP;
END $rv$;