-- Frozen candidate; root alone installs it with the 0014 schema migration.
-- Composite marker FK pairs its non-NULL timestamp with the append-only audit.
CREATE FUNCTION public.flowtrace_import_source_release_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $guard$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE = '55000', MESSAGE = 'import_stage_source_release_immutable';
END;
$guard$;

CREATE FUNCTION public.flowtrace_import_source_marker_immutable()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $guard$
BEGIN
    IF OLD.source_released_at IS NOT NULL
       AND NEW.source_released_at IS DISTINCT FROM OLD.source_released_at THEN
        RAISE EXCEPTION USING
            ERRCODE = '55000', MESSAGE = 'import_stage_source_marker_immutable';
    END IF;
    RETURN NEW;
END;
$guard$;

CREATE TRIGGER tr_import_source_release_immutable
BEFORE UPDATE OR DELETE ON public.import_stage_source_releases
FOR EACH ROW EXECUTE FUNCTION public.flowtrace_import_source_release_immutable();

CREATE TRIGGER tr_import_source_release_no_truncate
BEFORE TRUNCATE ON public.import_stage_source_releases
FOR EACH STATEMENT EXECUTE FUNCTION public.flowtrace_import_source_release_immutable();

CREATE TRIGGER tr_import_source_marker_immutable
BEFORE UPDATE ON public.import_stages
FOR EACH ROW EXECUTE FUNCTION public.flowtrace_import_source_marker_immutable();
