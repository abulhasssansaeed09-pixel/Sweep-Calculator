-- Keep cost records and financial reports private to owners. Closing RPCs retain point-only access.
alter policy reloads_read on public.reloads using (exists(select 1 from public.memberships m where m.workspace_id=reloads.workspace_id and m.user_id=(select auth.uid()) and m.role='owner'));
alter policy reloads_insert on public.reloads with check (exists(select 1 from public.memberships m where m.workspace_id=reloads.workspace_id and m.user_id=(select auth.uid()) and m.role='owner') and created_by=(select auth.uid()) and exists(select 1 from public.games g where g.id=reloads.game_id and g.workspace_id=reloads.workspace_id));
alter policy expenses_read on public.expenses using (exists(select 1 from public.memberships m where m.workspace_id=expenses.workspace_id and m.user_id=(select auth.uid()) and m.role='owner'));
alter policy expenses_insert on public.expenses with check (exists(select 1 from public.memberships m where m.workspace_id=expenses.workspace_id and m.user_id=(select auth.uid()) and m.role='owner') and created_by=(select auth.uid()));
alter policy expense_audit_read on public.expense_audit using (exists(select 1 from public.memberships m where m.workspace_id=expense_audit.workspace_id and m.user_id=(select auth.uid()) and m.role='owner') and public.team_access_active(workspace_id));
CREATE OR REPLACE FUNCTION public.workspace_extra_bonus_overview(p_workspace uuid)
 RETURNS TABLE(total_extra_bonus_points numeric, total_extra_bonus_cost numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if p_workspace is null or not public.team_access_active(p_workspace)
 or not exists(select 1 from public.memberships m where m.workspace_id=p_workspace and m.user_id=auth.uid() and m.role='owner')
 then raise exception 'Owner access required'; end if;
 return query select
   round(coalesce(sum(greatest(l.points-l.payment,0)),0),2),
   round(coalesce(sum(greatest(l.points-l.payment,0)*coalesce(l.purchase_rate,0)/100),0),2)
 from public.loads l where l.workspace_id=p_workspace;
end $function$;
CREATE OR REPLACE FUNCTION public.workspace_report_summary(p_workspace uuid, p_bucket text)
 RETURNS TABLE(period_label text, loads_count bigint, gross numeric, provider_fees numeric, points numeric, bonus_points numeric, cashouts_paid numeric, reload_cost numeric, expense_cost numeric, estimated_point_cost numeric, estimated_margin numeric, cash_flow numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not public.team_access_active(p_workspace) or not exists(select 1 from public.memberships m where m.workspace_id=p_workspace and m.user_id=auth.uid() and m.role='owner') then raise exception 'Owner access required';end if;
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
end $function$;
CREATE OR REPLACE FUNCTION public.workspace_report_summary_v2(p_workspace uuid, p_bucket text)
 RETURNS TABLE(period_label text, loads_count bigint, gross numeric, provider_fees numeric, points numeric, bonus_points numeric, cashouts_paid numeric, reload_cost numeric, expense_cost numeric, estimated_point_cost numeric, estimated_margin numeric, cash_flow numeric, cashout_owner_fees numeric, cashout_player_fees numeric, cashout_processor_debit numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not public.team_access_active(p_workspace) or not exists(select 1 from public.memberships m where m.workspace_id=p_workspace and m.user_id=auth.uid() and m.role='owner') then raise exception 'Owner access required';end if;
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
end $function$;
