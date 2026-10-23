-- Frozen downgrade companion. Drop guards before root drops their tables.
DROP TRIGGER tr_backup_hold_no_truncate ON public.backup_holds;
DROP TRIGGER tr_backup_hold_lifecycle ON public.backup_holds;
DROP TRIGGER tr_backup_pin_no_truncate ON public.backup_pins;
DROP TRIGGER tr_backup_pin_lifecycle ON public.backup_pins;
DROP TRIGGER tr_backup_retention_intent_no_truncate ON public.backup_retention_intents;
DROP TRIGGER tr_backup_retention_intent_immutable ON public.backup_retention_intents;

DROP FUNCTION public.flowtrace_backup_protection_truncate_rejected();
DROP FUNCTION public.flowtrace_backup_hold_lifecycle();
DROP FUNCTION public.flowtrace_backup_pin_lifecycle();
DROP FUNCTION public.flowtrace_backup_intent_immutable();
