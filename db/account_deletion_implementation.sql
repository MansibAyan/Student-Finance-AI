-- Student Finance AI: isolated account-deletion flow
-- Apply only after confirming the existing public.users(id) UUID primary key and the
-- Supabase function owner/role setup. This migration is transactional and rerunnable.
BEGIN;

CREATE TABLE IF NOT EXISTS public.pending_account_deletions (
  user_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  requested_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  CONSTRAINT pending_account_deletions_expiry_chk
    CHECK (expires_at > requested_at AND expires_at <= requested_at + interval '10 minutes')
);

ALTER TABLE public.pending_account_deletions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.pending_account_deletions FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.account_deletion_handle(p_user uuid, p_action jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $function$
DECLARE
  v_act text := p_action->>'action';
  v_expires timestamptz;
BEGIN
  IF p_user IS NULL OR p_action IS NULL OR jsonb_typeof(p_action) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid request');
  END IF;
  IF v_act NOT IN ('delete_account_request','delete_account_confirm') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unsupported deletion action');
  END IF;

  -- Serialize this request with normal user actions and refuse unknown/deleted accounts.
  PERFORM 1 FROM public.users WHERE id = p_user AND deleted_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'unknown user');
  END IF;

  IF v_act = 'delete_account_request' THEN
    INSERT INTO public.pending_account_deletions(user_id, requested_at, expires_at)
    VALUES (p_user, now(), now() + interval '10 minutes')
    ON CONFLICT (user_id) DO UPDATE
      SET requested_at = EXCLUDED.requested_at, expires_at = EXCLUDED.expires_at;
    RETURN jsonb_build_object(
      'ok', true,
      'message', 'Account deletion requested. To permanently delete your account and its database records, send exactly /deleteme confirm within 10 minutes. Any other message will not confirm deletion.'
    );
  END IF;

  SELECT expires_at INTO v_expires
  FROM public.pending_account_deletions
  WHERE user_id = p_user
    AND expires_at > clock_timestamp()
  FOR UPDATE;

  IF v_expires IS NULL THEN
    DELETE FROM public.pending_account_deletions WHERE user_id = p_user;
    RETURN jsonb_build_object('ok', false, 'error', 'No active deletion request. Send /deleteme first; requests expire after 10 minutes.');
  END IF;

  -- Remove the pending token first; all user-owned rows with ON DELETE CASCADE are removed
  -- by deleting the parent user row in the same transaction.
  DELETE FROM public.pending_account_deletions WHERE user_id = p_user;
  DELETE FROM public.users WHERE id = p_user AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'account could not be deleted';
  END IF;
  RETURN jsonb_build_object('ok', true, 'message', 'Your account and linked database records were deleted. Send /start to begin again.');
EXCEPTION
  WHEN OTHERS THEN
    -- Do not leak database internals. The transaction rolls back on raised errors.
    RETURN jsonb_build_object('ok', false, 'error', 'Account deletion failed; no confirmation of deletion was recorded. Please contact support.');
END;
$function$;

REVOKE ALL ON FUNCTION public.account_deletion_handle(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.account_deletion_handle(uuid, jsonb) TO service_role;

COMMIT;
