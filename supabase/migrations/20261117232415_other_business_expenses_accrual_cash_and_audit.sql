
alter table public.expenses
 add column category text not null default 'Other',
 add column expense_date date,
 add column payment_status text not null default 'paid',
 add column payment_date date,
 add column payment_method text,
 add column vendor text,
 add column notes text,
 add column receipt_name text,
 add column receipt_mime text,
 add column receipt_base64 text,
 add column updated_at timestamptz not null default now(),
 add column voided_at timestamptz,
 add column voided_by uuid references auth.users(id),
 add column void_reason text;
update public.expenses e set expense_date=(e.created_at at time zone w.closing_timezone)::date,payment_date=(e.created_at at time zone w.closing_timezone)::date,payment_method='Not specified (legacy)',updated_at=e.created_at from public.workspaces w where e.workspace_id=w.id;
alter table public.expenses alter column expense_date set not null,
 add constraint expense_category_valid check(category in ('Rent/Lease','Marketing','Software/Subscriptions','Internet/Phone','Utilities','Office Supplies','Payroll/Contractors','Professional Services','Shipping/Delivery','Repairs/Maintenance','Taxes/Licenses','Other')),
 add constraint expense_amount_finite check(amount>0 and amount<1000000000000),
 add constraint expense_payment_valid check((payment_status='paid' and payment_date is not null and nullif(btrim(payment_method),'') is not null) or (payment_status='unpaid' and payment_date is null)),
 add constraint expense_void_valid check((voided_at is null and voided_by is null and void_reason is null) or (voided_at is not null and voided_by is not null and void_reason is not null and length(btrim(void_reason))>=3)),
 add constraint expense_receipt_valid check((receipt_name is null and receipt_mime is null and receipt_base64 is null) or (receipt_name is not null and receipt_mime is not null and receipt_base64 is not null and length(receipt_name) between 1 and 255 and receipt_mime in ('application/pdf','image/png','image/jpeg','image/webp') and length(receipt_base64) between 4 and 2800000 and receipt_base64 ~ '^[A-Za-z0-9+/]+={0,2}$')),
 add constraint expense_description_valid check(length(btrim(description))>0 and length(description)<=500 and length(coalesce(vendor,''))<=250 and length(coalesce(notes,''))<=5000 and length(coalesce(payment_method,''))<=250 and length(coalesce(void_reason,''))<=500);
create index expenses_business_date_idx on public.expenses(workspace_id,expense_date) where voided_at is null;
create index expenses_payment_date_idx on public.expenses(workspace_id,payment_date) where voided_at is null and payment_status='paid';
create table public.expense_audit(
 id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.workspaces(id) on delete cascade,
 expense_id uuid not null references public.expenses(id),actor_id uuid references auth.users(id),action text not null check(action in ('created','edited','voided')),
 old_record jsonb,new_record jsonb not null,created_at timestamptz not null default now()
);
insert into public.expense_audit(workspace_id,expense_id,actor_id,action,new_record,created_at) select workspace_id,id,created_by,'created',to_jsonb(e)-'receipt_base64',created_at from public.expenses e;
create index expense_audit_expense_idx on public.expense_audit(workspace_id,expense_id,created_at desc);
alter table public.expense_audit enable row level security;
revoke all on public.expense_audit from anon,authenticated;
grant select on public.expense_audit to authenticated;
create policy expense_audit_read on public.expense_audit for select to authenticated using(public.is_workspace_manager(workspace_id) and public.team_access_active(workspace_id));
revoke all on public.expenses from anon;
revoke truncate,trigger,references,delete on public.expenses from authenticated;
grant update(description,category,amount,expense_date,payment_status,payment_date,payment_method,vendor,notes,receipt_name,receipt_mime,receipt_base64,voided_at,void_reason) on public.expenses to authenticated;
create policy expenses_owner_update on public.expenses for update to authenticated
 using (exists(select 1 from public.memberships m where m.workspace_id=expenses.workspace_id and m.user_id=(select auth.uid()) and m.role='owner'))
 with check (exists(select 1 from public.memberships m where m.workspace_id=expenses.workspace_id and m.user_id=(select auth.uid()) and m.role='owner'));
create function private.validate_business_expense() returns trigger language plpgsql security invoker set search_path='' as $$
declare today date;
begin
 select (now() at time zone w.closing_timezone)::date into today from public.workspaces w where w.id=new.workspace_id;
 if tg_op='INSERT' then
   new.expense_date:=coalesce(new.expense_date,(new.created_at at time zone (select w.closing_timezone from public.workspaces w where w.id=new.workspace_id))::date);
   if new.payment_status='paid' and new.payment_date is null and new.payment_method is null then
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
end $$;
create trigger expense_validate_before before insert or update on public.expenses for each row execute function private.validate_business_expense();
create function private.audit_business_expense() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.expense_audit(workspace_id,expense_id,actor_id,action,old_record,new_record)
 values(new.workspace_id,new.id,auth.uid(),case when tg_op='INSERT' then 'created' when new.voided_at is not null then 'voided' else 'edited' end,
 case when tg_op='INSERT' then null else to_jsonb(old)-'receipt_base64' end,to_jsonb(new)-'receipt_base64');
 return new;
end $$;
revoke all on function private.audit_business_expense() from public,anon,authenticated;
create trigger expense_audit_after after insert or update on public.expenses for each row execute function private.audit_business_expense();
CREATE OR REPLACE FUNCTION public.workspace_report_summary_v2(p_workspace uuid, p_bucket text)
 RETURNS TABLE(period_label text, loads_count bigint, gross numeric, provider_fees numeric, points numeric, bonus_points numeric, cashouts_paid numeric, reload_cost numeric, expense_cost numeric, estimated_point_cost numeric, estimated_margin numeric, cash_flow numeric, cashout_owner_fees numeric, cashout_player_fees numeric, cashout_processor_debit numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not public.team_access_active(p_workspace) or not public.is_workspace_manager(p_workspace) then raise exception 'Manager/Owner required';end if;
 if p_bucket not in ('day','week','month') then raise exception 'Invalid report interval';end if;
 return query
 with settings as (select closing_timezone as tz from public.workspaces where id=p_workspace),
 facts as (
 select l.created_at,1::bigint n,l.payment as g,(l.payment*l.rate/100+l.fixed_fee) as fees,l.points as pts,
  (l.points-l.payment) as bonus,0::numeric as co,0::numeric as rc,0::numeric as ex,
  (l.points*l.purchase_rate/100) as point_cost,0::numeric owner_fee,0::numeric player_fee,0::numeric debit,0::numeric as paid_ex
 from public.loads l where l.workspace_id=p_workspace
 union all
 select c.created_at,0::bigint,0::numeric,0::numeric,0::numeric,0::numeric,c.net_paid,0::numeric,0::numeric,
  -(c.points*coalesce(c.backend_purchase_rate,g.purchase_rate,0)/100),case when c.fee_bearer='owner' then round(c.gross_amount*c.fee_rate/100+c.fee_fixed,2) else 0 end,case when c.fee_bearer='player' then c.gross_amount-c.net_paid else 0 end,c.gross_amount+case when c.fee_bearer='owner' then round(c.gross_amount*c.fee_rate/100+c.fee_fixed,2) else 0 end,0::numeric as paid_ex
 from public.cashouts c join public.games g on g.id=c.game_id where c.workspace_id=p_workspace
 union all
 select r.created_at,0::bigint,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,r.points*r.rate/100,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric as paid_ex
 from public.reloads r where r.workspace_id=p_workspace
 union all
 select (x.expense_date::timestamp at time zone (select tz from settings)),0::bigint,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,x.amount,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric
 from public.expenses x where x.workspace_id=p_workspace and x.voided_at is null
 union all
 select (x.payment_date::timestamp at time zone (select tz from settings)),0::bigint,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,x.amount
 from public.expenses x where x.workspace_id=p_workspace and x.voided_at is null and x.payment_status='paid' and x.payment_date is not null
 ),
 agg as (
 select (date_trunc(p_bucket,f.created_at at time zone (select tz from settings)))::date as bucket,
  sum(f.n)::bigint as cnt,sum(f.g) gross,sum(f.fees) fees,sum(f.pts) pts,sum(f.bonus) bonus,
  sum(f.co) co,sum(f.rc) rc,sum(f.ex) ex,sum(f.paid_ex) paid_ex,sum(f.point_cost) cost,sum(f.owner_fee) owner_fee,sum(f.player_fee) player_fee,sum(f.debit) debit
 from facts f group by 1
 )
 select a.bucket::text,a.cnt,round(a.gross,2),round(a.fees,2),round(a.pts,2),round(a.bonus,2),
  round(a.co,2),round(a.rc,2),round(a.ex,2),round(a.cost,2),
  round(a.gross-a.fees-a.debit-a.ex-a.cost,2),
  round(a.gross-a.fees-a.debit-a.rc-a.paid_ex,2),round(a.owner_fee,2),round(a.player_fee,2),round(a.debit,2)
 from agg a order by a.bucket desc;
end $function$
;
CREATE OR REPLACE FUNCTION public.workspace_report_summary(p_workspace uuid, p_bucket text)
 RETURNS TABLE(period_label text, loads_count bigint, gross numeric, provider_fees numeric, points numeric, bonus_points numeric, cashouts_paid numeric, reload_cost numeric, expense_cost numeric, estimated_point_cost numeric, estimated_margin numeric, cash_flow numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not public.team_access_active(p_workspace) or not public.is_workspace_manager(p_workspace) then raise exception 'Manager/Owner required';end if;
 if p_bucket not in ('day','week','month') then raise exception 'Invalid report interval';end if;
 return query
 with settings as (select closing_timezone as tz from public.workspaces where id=p_workspace),
 facts as (
 select l.created_at,1::bigint n,l.payment as g,(l.payment*l.rate/100+l.fixed_fee) as fees,l.points as pts,
  (l.points-l.payment) as bonus,0::numeric as co,0::numeric as rc,0::numeric as ex,
  (l.points*l.purchase_rate/100) as point_cost,0::numeric as paid_ex
 from public.loads l where l.workspace_id=p_workspace
 union all
 select c.created_at,0::bigint,0::numeric,round(c.gross_amount*c.fee_rate/100+c.fee_fixed,2),0::numeric,0::numeric,c.net_paid,0::numeric,0::numeric,
  -(c.points*coalesce(c.backend_purchase_rate,g.purchase_rate,0)/100),0::numeric as paid_ex
 from public.cashouts c join public.games g on g.id=c.game_id where c.workspace_id=p_workspace
 union all
 select r.created_at,0::bigint,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,r.points*r.rate/100,0::numeric,0::numeric,0::numeric as paid_ex
 from public.reloads r where r.workspace_id=p_workspace
 union all
 select (x.expense_date::timestamp at time zone (select tz from settings)),0::bigint,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,x.amount,0::numeric,0::numeric
 from public.expenses x where x.workspace_id=p_workspace and x.voided_at is null
 union all
 select (x.payment_date::timestamp at time zone (select tz from settings)),0::bigint,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,x.amount
 from public.expenses x where x.workspace_id=p_workspace and x.voided_at is null and x.payment_status='paid' and x.payment_date is not null
 ),
 agg as (
 select (date_trunc(p_bucket,f.created_at at time zone (select tz from settings)))::date as bucket,
  sum(f.n)::bigint as cnt,sum(f.g) gross,sum(f.fees) fees,sum(f.pts) pts,sum(f.bonus) bonus,
  sum(f.co) co,sum(f.rc) rc,sum(f.ex) ex,sum(f.paid_ex) paid_ex,sum(f.point_cost) cost
 from facts f group by 1
 )
 select a.bucket::text,a.cnt,round(a.gross,2),round(a.fees,2),round(a.pts,2),round(a.bonus,2),
  round(a.co,2),round(a.rc,2),round(a.ex,2),round(a.cost,2),
  round(a.gross-a.fees-a.co-a.ex-a.cost,2),
  round(a.gross-a.fees-a.co-a.rc-a.paid_ex,2)
 from agg a order by a.bucket desc;
end $function$
;
