CREATE OR REPLACE FUNCTION private.validate_business_expense()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare today date; legacy_insert boolean;
begin
 select (now() at time zone w.closing_timezone)::date into today from public.workspaces w where w.id=new.workspace_id;
 if tg_op='INSERT' then
   legacy_insert:=new.expense_date is null;
   new.expense_date:=coalesce(new.expense_date,(new.created_at at time zone (select w.closing_timezone from public.workspaces w where w.id=new.workspace_id))::date);
   if legacy_insert and new.payment_status='paid' and new.payment_date is null and new.payment_method is null then
     new.payment_date:=new.expense_date;new.payment_method:='Not specified (legacy)';
   end if;
   if new.voided_at is not null or new.voided_by is not null or new.void_reason is not null then raise exception 'New expense cannot be voided';end if;
 elsif tg_op='UPDATE' then
   if old.voided_at is not null then raise exception 'Voided expense is immutable';end if;
   if (new.id,new.workspace_id,new.created_by,new.created_at) is distinct from (old.id,old.workspace_id,old.created_by,old.created_at) then raise exception 'Expense identity is immutable';end if;
   if new.voided_at is not null then
     if (to_jsonb(new)-'voided_at'-'voided_by'-'void_reason'-'updated_at') is distinct from (to_jsonb(old)-'voided_at'-'voided_by'-'void_reason'-'updated_at') then raise exception 'Void separately from editing';end if;
     new.voided_at:=now();new.voided_by:=auth.uid();
   end if;
 end if;
 if today is null or new.expense_date>today or new.expense_date<'1900-01-01'::date or (new.payment_date is not null and (new.payment_date>today or new.payment_date<'1900-01-01'::date)) then raise exception 'Expense and payment dates must be valid, not in the future';end if;
 new.updated_at:=clock_timestamp();
 return new;
end $function$
;
