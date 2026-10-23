-- Frozen review candidate only: not an installed migration or runtime hook.
-- Root owns migration registration. Application CAS still authorizes releases.
-- These guards preserve history; they do not execute any backup file effect.

CREATE FUNCTION public.flowtrace_backup_intent_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $guard$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '55000', MESSAGE = 'backup_retention_intent_immutable';
END;
$guard$;

CREATE FUNCTION public.flowtrace_backup_pin_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $guard$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.version IS DISTINCT FROM 1
           OR NEW.released_at IS NOT NULL
           OR NEW.released_by IS NOT NULL
           OR NEW.release_request_id IS NOT NULL
           OR NEW.release_request_hash IS NOT NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = '55000', MESSAGE = 'backup_pin_lifecycle_invalid';
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.version IS DISTINCT FROM 1
           OR NEW.version IS DISTINCT FROM 2
           OR OLD.released_at IS NOT NULL
           OR OLD.released_by IS NOT NULL
           OR OLD.release_request_id IS NOT NULL
           OR OLD.release_request_hash IS NOT NULL
           OR NEW.released_at IS NULL
           OR NEW.released_by IS NULL
           OR NEW.release_request_id IS NULL
           OR NEW.release_request_hash IS NULL
           OR (to_jsonb(NEW) - ARRAY[
               'version', 'released_at', 'released_by',
               'release_request_id', 'release_request_hash'
           ]::text[]) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY[
               'version', 'released_at', 'released_by',
               'release_request_id', 'release_request_hash'
           ]::text[]) THEN
            RAISE EXCEPTION USING
                ERRCODE = '55000', MESSAGE = 'backup_pin_lifecycle_invalid';
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION USING
        ERRCODE = '55000', MESSAGE = 'backup_pin_immutable';
END;
$guard$;

CREATE FUNCTION public.flowtrace_backup_hold_lifecycle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $guard$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.version IS DISTINCT FROM 1
           OR NEW.released_at IS NOT NULL
           OR NEW.release_proof IS NOT NULL THEN
            RAISE EXCEPTION USING
                ERRCODE = '55000', MESSAGE = 'backup_hold_lifecycle_invalid';
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.version IS DISTINCT FROM 1
           OR NEW.version IS DISTINCT FROM 2
           OR OLD.released_at IS NOT NULL
           OR OLD.release_proof IS NOT NULL
           OR NEW.released_at IS NULL
           OR NEW.release_proof IS NULL
           OR (to_jsonb(NEW) - ARRAY[
               'version', 'released_at', 'release_proof'
           ]::text[]) IS DISTINCT FROM (to_jsonb(OLD) - ARRAY[
               'version', 'released_at', 'release_proof'
           ]::text[]) THEN
            RAISE EXCEPTION USING
                ERRCODE = '55000', MESSAGE = 'backup_hold_lifecycle_invalid';
        END IF;
        RETURN NEW;
    END IF;
    RAISE EXCEPTION USING
        ERRCODE = '55000', MESSAGE = 'backup_hold_immutable';
END;
$guard$;

CREATE FUNCTION public.flowtrace_backup_protection_truncate_rejected()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $guard$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '55000', MESSAGE = 'backup_protection_truncate_rejected';
END;
$guard$;

CREATE TRIGGER tr_backup_retention_intent_immutable
BEFORE UPDATE OR DELETE ON public.backup_retention_intents
FOR EACH ROW EXECUTE FUNCTION public.flowtrace_backup_intent_immutable();

CREATE TRIGGER tr_backup_retention_intent_no_truncate
BEFORE TRUNCATE ON public.backup_retention_intents
FOR EACH STATEMENT EXECUTE FUNCTION public.flowtrace_backup_intent_immutable();

CREATE TRIGGER tr_backup_pin_lifecycle
BEFORE INSERT OR UPDATE OR DELETE ON public.backup_pins
FOR EACH ROW EXECUTE FUNCTION public.flowtrace_backup_pin_lifecycle();

CREATE TRIGGER tr_backup_pin_no_truncate
BEFORE TRUNCATE ON public.backup_pins
FOR EACH STATEMENT
EXECUTE FUNCTION public.flowtrace_backup_protection_truncate_rejected();

CREATE TRIGGER tr_backup_hold_lifecycle
BEFORE INSERT OR UPDATE OR DELETE ON public.backup_holds
FOR EACH ROW EXECUTE FUNCTION public.flowtrace_backup_hold_lifecycle();

CREATE TRIGGER tr_backup_hold_no_truncate
BEFORE TRUNCATE ON public.backup_holds
FOR EACH STATEMENT
EXECUTE FUNCTION public.flowtrace_backup_protection_truncate_rejected();
