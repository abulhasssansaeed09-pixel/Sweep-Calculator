-- Per-merchant cash-out rates; incoming provider fees remain independent.
alter table public.providers add column cashout_rate numeric check (cashout_rate >= 0 and cashout_rate <= 100), add column cashout_fixed_fee numeric not null default 0 check (cashout_fixed_fee >= 0), add column receive_enabled boolean not null default true;
-- Preserve any explicitly configured legacy platform rate on existing providers.
update public.providers p set cashout_rate=r.fee_rate,cashout_fixed_fee=r.fee_fixed
from public.platform_cashout_rules r where r.workspace_id=p.workspace_id;
create or replace function private.guard_provider_cashout_config() returns trigger language plpgsql set search_path='' as $$
begin
 if TG_OP='INSERT' then
  if new.cashout_rate is null and new.cashout_fixed_fee=0 and new.receive_enabled then return new; end if;
 else
  if new.cashout_rate is not distinct from old.cashout_rate and new.cashout_fixed_fee is not distinct from old.cashout_fixed_fee and new.receive_enabled is not distinct from old.receive_enabled then return new;end if;
 end if;
 if auth.uid() is not null and not exists(select 1 from public.memberships m where m.workspace_id=new.workspace_id and m.user_id=auth.uid() and m.role='owner') then raise exception 'Only the Owner may configure cash-out merchants';end if;
 return new;
end $$;
create trigger guard_provider_cashout_config before insert or update on public.providers for each row execute function private.guard_provider_cashout_config();

create or replace function public.save_cashout_merchant(p_workspace uuid,p_provider uuid,p_company text,p_method text,p_rate numeric,p_fixed numeric) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 if not public.team_access_active(p_workspace) or not exists(select 1 from public.memberships m where m.workspace_id=p_workspace and m.user_id=auth.uid() and m.role='owner') then raise exception 'Owner access required';end if;
 if p_rate is null or p_rate<0 or p_rate>100 or p_fixed is null or p_fixed<0 or p_fixed>100000000 or round(p_fixed,2)<>p_fixed then raise exception 'Invalid merchant fee';end if;
 if p_provider is null then
  if length(btrim(coalesce(p_company,'')))=0 or length(btrim(coalesce(p_method,'')))=0 then raise exception 'Merchant company and method required';end if;
  insert into public.providers(workspace_id,company,method,rate,fixed_fee,receive_enabled,cashout_rate,cashout_fixed_fee) values(p_workspace,btrim(p_company),btrim(p_method),0,0,false,p_rate,p_fixed) returning id into result;
 else
  update public.providers set cashout_rate=p_rate,cashout_fixed_fee=p_fixed where id=p_provider and workspace_id=p_workspace returning id into result;
  if result is null then raise exception 'Unknown merchant';end if;
 end if;
 return result;
end $$;
revoke all on function public.save_cashout_merchant(uuid,uuid,text,text,numeric,numeric) from public,anon;
grant execute on function public.save_cashout_merchant(uuid,uuid,text,text,numeric,numeric) to authenticated;

create or replace function public.workspace_cashout_fee_bearer(p_workspace uuid) returns text language plpgsql stable security definer set search_path='' as $$
begin
 if not public.team_access_active(p_workspace) or not public.is_workspace_member(p_workspace) then raise exception 'Active workspace membership required';end if;
 return coalesce((select r.fee_bearer from public.platform_cashout_rules r where r.workspace_id=p_workspace),'player');
end $$;
revoke all on function public.workspace_cashout_fee_bearer(uuid) from public,anon;
grant execute on function public.workspace_cashout_fee_bearer(uuid) to authenticated;
CREATE OR REPLACE FUNCTION public.record_cashout(p_player uuid, p_game uuid, p_provider uuid, p_points numeric, p_gross numeric, p_note text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare w uuid; p public.providers%rowtype; g public.games%rowtype; rules public.platform_cashout_rules%rowtype; r public.cashouts%rowtype; last_points numeric; minimum numeric; fee numeric; paid numeric; suspicious boolean; why text;
begin
 select gg.workspace_id into w from public.games gg where gg.id=p_game;
 if w is null or not public.team_access_active(w) or not exists(select 1 from public.memberships m where m.workspace_id=w and m.user_id=auth.uid()) then raise exception 'Not a workspace member'; end if;
 if not exists(select 1 from public.players x where x.id=p_player and x.workspace_id=w) then raise exception 'Invalid player'; end if;
 select * into g from public.games where id=p_game and workspace_id=w;
 select * into p from public.providers where id=p_provider and workspace_id=w;
 select * into rules from public.platform_cashout_rules where workspace_id=w;
 if g.id is null or p.id is null or p_points is null or p_gross is null or p_points<=0 or p_gross<=0 then raise exception 'Invalid cash-out details'; end if;
 select l.points into last_points from public.loads l where l.workspace_id=w and l.player_id=p_player and l.game_id=p_game order by l.created_at desc limit 1;
 if p.cashout_rate is null then raise exception 'Owner must configure fees for this cash-out merchant';end if;
 if p_gross>100000000 or round(p_gross,2)<>p_gross or round(p_points,2)<>p_points then raise exception 'Enter valid amounts with up to two decimals';end if;
 minimum:=coalesce(last_points,0)*coalesce(rules.min_multiplier,3);
 fee:=round((p_gross*p.cashout_rate/100+p.cashout_fixed_fee)::numeric,2);
 paid:=case when coalesce(rules.fee_bearer,'player')='player' then p_gross-fee else p_gross end;
 if paid<0 then raise exception 'Cash-out fee exceeds payout'; end if;
 suspicious:=last_points is null or p_points<minimum or (rules.max_points is not null and p_points>rules.max_points);
 why:=case when last_points is null then 'No prior load found for this player/backend' when p_points<minimum then 'Redeemed points below configured minimum' when rules.max_points is not null and p_points>rules.max_points then 'Redeemed points exceed configured maximum' else null end;
 insert into public.cashouts(workspace_id,player_id,game_id,provider_id,points,gross_amount,fee_rate,fee_fixed,fee_bearer,net_paid,note,review_status,review_reason,backend_purchase_rate)
 values(w,p_player,p_game,p_provider,p_points,p_gross,p.cashout_rate,p.cashout_fixed_fee,coalesce(rules.fee_bearer,'player'),paid,coalesce(p_note,''),case when suspicious then 'review_required' else 'clear' end,why,g.purchase_rate) returning * into r;
 insert into public.cashout_audit(cashout_id,workspace_id,action,reason,new_record) values(r.id,w,'created','Cash-out recorded',to_jsonb(r));
 if suspicious then insert into public.cashout_notifications(workspace_id,cashout_id,kind) values(w,r.id,'review_required'); end if;
 return r.id;
end $function$;
CREATE OR REPLACE FUNCTION public.update_platform_cashout_rules(p_workspace uuid, p_min_multiplier numeric, p_max_points numeric, p_fee_rate numeric, p_fee_fixed numeric, p_fee_bearer text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not public.team_access_active(p_workspace) or not exists(select 1 from public.memberships m where m.workspace_id=p_workspace and m.user_id=auth.uid() and m.role='owner') then raise exception 'Owner access required'; end if;
 if p_min_multiplier is null or p_min_multiplier<0 or p_max_points is null or p_max_points<0 or p_fee_rate is null or p_fee_rate<0 or p_fee_rate>100 or p_fee_fixed is null or p_fee_fixed<0 or p_fee_bearer is null or p_fee_bearer not in ('owner','player') then raise exception 'Invalid cash-out rule'; end if;
 insert into public.platform_cashout_rules(workspace_id,min_multiplier,max_points,fee_rate,fee_fixed,fee_bearer)
 values(p_workspace,p_min_multiplier,nullif(p_max_points,0),0,0,p_fee_bearer)
 on conflict(workspace_id) do update set min_multiplier=excluded.min_multiplier,max_points=excluded.max_points,fee_rate=excluded.fee_rate,fee_fixed=excluded.fee_fixed,fee_bearer=excluded.fee_bearer;
end $function$;
CREATE OR REPLACE FUNCTION public.record_load_points(p_player uuid, p_game uuid, p_provider uuid, p_payment numeric, p_points numeric, p_note text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pr public.players%rowtype; g public.games%rowtype; provider public.providers%rowtype; new_id uuid;
begin
 select * into pr from public.players where id=p_player;
 if pr.id is null or not public.team_access_active(pr.workspace_id) or not public.is_workspace_member(pr.workspace_id)
 then raise exception 'Active team membership required';end if;
 select * into g from public.games where id=p_game and workspace_id=pr.workspace_id;
 select * into provider from public.providers where id=p_provider and workspace_id=pr.workspace_id;
 if g.id is null or provider.id is null or not provider.receive_enabled then raise exception 'Invalid backend or provider';end if;
 if p_payment is null or p_payment<=0 or p_payment>100000000 or round(p_payment,2)<>p_payment
 then raise exception 'Enter received payment with up to two decimals';end if;
 if p_points is null or p_points<p_payment or p_points>200000000 or round(p_points,2)<>p_points
 then raise exception 'Loaded points must be at least the received amount';end if;
 insert into public.loads(workspace_id,player_id,game_id,provider_id,payment,points,rate,fixed_fee,purchase_rate,note,created_by)
 values(pr.workspace_id,p_player,p_game,p_provider,p_payment,p_points,
 provider.rate,provider.fixed_fee,g.purchase_rate,nullif(btrim(coalesce(p_note,'')),''),auth.uid())
 returning id into new_id;
 return new_id;
end $function$;
CREATE OR REPLACE FUNCTION private.apply_load_points_change(p_load uuid, p_player uuid, p_game uuid, p_provider uuid, p_payment numeric, p_note text, p_reason text, p_points numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old_load public.loads%rowtype; new_load public.loads%rowtype;
 pr public.players%rowtype; g public.games%rowtype; provider public.providers%rowtype;
begin
 select * into old_load from public.loads where id=p_load for update;
 if old_load.id is null then raise exception 'Load not found';end if;
 if p_payment is null or p_payment<=0 or p_payment>100000000 or round(p_payment,2)<>p_payment
 then raise exception 'Payment must be a positive amount with up to two decimals';end if;
 if p_points is null or p_points<p_payment or p_points>200000000 or round(p_points,2)<>p_points
 then raise exception 'Points loaded must be at least payment received (up to two decimals)';end if;
 select * into pr from public.players where id=p_player and workspace_id=old_load.workspace_id;
 select * into g from public.games where id=p_game and workspace_id=old_load.workspace_id;
 select * into provider from public.providers where id=p_provider and workspace_id=old_load.workspace_id;
 if pr.id is null or g.id is null or provider.id is null or not provider.receive_enabled then raise exception 'Invalid player, backend or provider';end if;
 update public.loads set player_id=p_player,game_id=p_game,provider_id=p_provider,
 payment=p_payment,points=p_points,
 rate=case when old_load.provider_id=p_provider then old_load.rate else provider.rate end,
 fixed_fee=case when old_load.provider_id=p_provider then old_load.fixed_fee else provider.fixed_fee end,
 purchase_rate=case when old_load.game_id=p_game then old_load.purchase_rate else g.purchase_rate end,
 note=p_note,updated_at=now(),correction_reason=p_reason
 where id=p_load returning * into new_load;
 insert into public.load_correction_audit(workspace_id,load_id,actor_id,reason,old_record,new_record)
 values(old_load.workspace_id,p_load,auth.uid(),p_reason,to_jsonb(old_load),to_jsonb(new_load));
 update public.closings c set
  recorded_load_points=(select coalesce(sum(l.points),0) from public.loads l where l.workspace_id=c.workspace_id and l.game_id=c.game_id and l.created_at>c.period_start and l.created_at<=c.period_end),
  difference=c.actual_used_points-(select coalesce(sum(l.points),0) from public.loads l where l.workspace_id=c.workspace_id and l.game_id=c.game_id and l.created_at>c.period_start and l.created_at<=c.period_end),
  review_status='review_required',review_reason='Historical load correction changed closed-period totals'
 where c.workspace_id=old_load.workspace_id and c.actual_used_points is not null
 and c.game_id in(old_load.game_id,p_game) and old_load.created_at>c.period_start and old_load.created_at<=c.period_end;
end $function$;
CREATE OR REPLACE FUNCTION public.submit_load_points_correction(p_load uuid, p_player uuid, p_game uuid, p_provider uuid, p_payment numeric, p_points numeric, p_note text, p_reason text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old_load public.loads%rowtype; actor_role text;
begin
 select * into old_load from public.loads where id=p_load for update;
 if old_load.id is null or not public.team_access_active(old_load.workspace_id)
 then raise exception 'Load missing or account disabled';end if;
 select role into actor_role from public.memberships where workspace_id=old_load.workspace_id and user_id=auth.uid();
 if actor_role is null then raise exception 'Not a workspace member';end if;
 if actor_role='worker' and old_load.created_by<>auth.uid() then raise exception 'Only your own loads may be corrected';end if;
 if p_payment is null or p_payment<=0 or p_payment>100000000 or round(p_payment,2)<>p_payment
 or length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Valid payment and reason required';end if;
 if p_points is null or p_points<p_payment or p_points>200000000 or round(p_points,2)<>p_points
 then raise exception 'Loaded points cannot be lower than payment received';end if;
 if not exists(select 1 from public.players p where p.id=p_player and p.workspace_id=old_load.workspace_id)
 or not exists(select 1 from public.games g where g.id=p_game and g.workspace_id=old_load.workspace_id)
 or not exists(select 1 from public.providers p where p.id=p_provider and p.workspace_id=old_load.workspace_id and p.receive_enabled)
 then raise exception 'Invalid player, backend or provider';end if;
 if actor_role in('owner','manager') or now()<=old_load.created_at+interval '15 minutes' then
  perform private.apply_load_points_change(p_load,p_player,p_game,p_provider,p_payment,p_note,p_reason,p_points);
  return 'applied';
 end if;
 insert into public.load_correction_requests(workspace_id,load_id,requested_by,requested_player_id,requested_game_id,requested_provider_id,requested_payment,requested_points,requested_note,reason)
 values(old_load.workspace_id,p_load,auth.uid(),p_player,p_game,p_provider,p_payment,p_points,p_note,p_reason);
 return 'pending_approval';
end $function$;
CREATE OR REPLACE FUNCTION public.record_payment_reconciliation(p_provider uuid, p_start timestamp with time zone, p_end timestamp with time zone, p_actual numeric, p_note text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare w uuid; expected numeric; rid uuid;
begin
 select workspace_id into w from public.providers where id=p_provider;
 if w is null or not public.team_access_active(w) or not public.is_workspace_manager(w) then raise exception 'Manager/Owner required';end if;
 if p_start is null or p_end is null or p_end<=p_start or p_end>now()+interval '1 day' then raise exception 'Invalid reconciliation period';end if;
 if p_actual is null or length(btrim(coalesce(p_note,'')))<3 then raise exception 'Actual amount and notes required';end if;
 select coalesce(sum(l.payment-l.payment*l.rate/100-l.fixed_fee),0) into expected
 from public.loads l where l.provider_id=p_provider and l.workspace_id=w and l.created_at>=p_start and l.created_at<p_end;
 expected:=expected-coalesce((select sum(c.gross_amount+case when c.fee_bearer='owner' then round(c.gross_amount*c.fee_rate/100+c.fee_fixed,2) else 0 end) from public.cashouts c
 where c.provider_id=p_provider and c.workspace_id=w and c.created_at>=p_start and c.created_at<p_end),0);
 insert into public.payment_reconciliations(workspace_id,provider_id,period_start,period_end,actual_net,expected_net,note,created_by,review_status)
 values(w,p_provider,p_start,p_end,p_actual,round(expected,2),p_note,auth.uid(),
  case when abs(round(expected,2)-p_actual)>0.01 then 'mismatch' else 'matched' end)
 returning id into rid;
 return rid;
end $function$;
CREATE OR REPLACE FUNCTION public.mark_payment_settlements_stale()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare changed_at timestamptz;
begin
 if TG_TABLE_NAME='loads' then
  if old.provider_id is not distinct from new.provider_id and old.payment is not distinct from new.payment
   and old.rate is not distinct from new.rate and old.fixed_fee is not distinct from new.fixed_fee then return new;end if;
 elsif TG_TABLE_NAME='cashouts' then
  if old.provider_id is not distinct from new.provider_id and old.net_paid is not distinct from new.net_paid and old.gross_amount is not distinct from new.gross_amount and old.fee_rate is not distinct from new.fee_rate and old.fee_fixed is not distinct from new.fee_fixed and old.fee_bearer is not distinct from new.fee_bearer then return new;end if;
 end if;
 changed_at:=old.created_at;
 update public.payment_reconciliations r set review_status='stale',review_reason='Financial transaction corrected; reconcile this provider and period again'
 where r.workspace_id=old.workspace_id and (r.provider_id=old.provider_id or r.provider_id=new.provider_id)
 and changed_at>=r.period_start and changed_at<r.period_end and r.review_status<>'stale';
 return new;
end $function$;
-- Old reconciliations calculated under the previous player-fee model require rechecking.
update public.payment_reconciliations r set review_status='stale',review_reason='Player-paid cash-out fees now included in processor debit; reconcile again'
where r.review_status<>'stale' and exists(select 1 from public.cashouts c where c.workspace_id=r.workspace_id and c.provider_id=r.provider_id and c.created_at>=r.period_start and c.created_at<r.period_end and c.fee_bearer='player' and c.gross_amount<>c.net_paid);
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
  (l.points*l.purchase_rate/100) as point_cost
 from public.loads l where l.workspace_id=p_workspace
 union all
 select c.created_at,0::bigint,0::numeric,round(c.gross_amount*c.fee_rate/100+c.fee_fixed,2),0::numeric,0::numeric,c.net_paid,0::numeric,0::numeric,
  -(c.points*coalesce(c.backend_purchase_rate,g.purchase_rate,0)/100)
 from public.cashouts c join public.games g on g.id=c.game_id where c.workspace_id=p_workspace
 union all
 select r.created_at,0::bigint,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,r.points*r.rate/100,0::numeric,0::numeric
 from public.reloads r where r.workspace_id=p_workspace
 union all
 select x.created_at,0::bigint,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,x.amount,0::numeric
 from public.expenses x where x.workspace_id=p_workspace
 ),
 agg as (
 select (date_trunc(p_bucket,f.created_at at time zone (select tz from settings)))::date as bucket,
  sum(f.n)::bigint as cnt,sum(f.g) gross,sum(f.fees) fees,sum(f.pts) pts,sum(f.bonus) bonus,
  sum(f.co) co,sum(f.rc) rc,sum(f.ex) ex,sum(f.point_cost) cost
 from facts f group by 1
 )
 select a.bucket::text,a.cnt,round(a.gross,2),round(a.fees,2),round(a.pts,2),round(a.bonus,2),
  round(a.co,2),round(a.rc,2),round(a.ex,2),round(a.cost,2),
  round(a.gross-a.fees-a.co-a.ex-a.cost,2),
  round(a.gross-a.fees-a.co-a.rc-a.ex,2)
 from agg a order by a.bucket desc;
end $function$;
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
  (l.points*l.purchase_rate/100) as point_cost,0::numeric owner_fee,0::numeric player_fee,0::numeric debit
 from public.loads l where l.workspace_id=p_workspace
 union all
 select c.created_at,0::bigint,0::numeric,0::numeric,0::numeric,0::numeric,c.net_paid,0::numeric,0::numeric,
  -(c.points*coalesce(c.backend_purchase_rate,g.purchase_rate,0)/100),case when c.fee_bearer='owner' then round(c.gross_amount*c.fee_rate/100+c.fee_fixed,2) else 0 end,case when c.fee_bearer='player' then c.gross_amount-c.net_paid else 0 end,c.gross_amount+case when c.fee_bearer='owner' then round(c.gross_amount*c.fee_rate/100+c.fee_fixed,2) else 0 end
 from public.cashouts c join public.games g on g.id=c.game_id where c.workspace_id=p_workspace
 union all
 select r.created_at,0::bigint,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,r.points*r.rate/100,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric
 from public.reloads r where r.workspace_id=p_workspace
 union all
 select x.created_at,0::bigint,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,0::numeric,x.amount,0::numeric,0::numeric,0::numeric,0::numeric
 from public.expenses x where x.workspace_id=p_workspace
 ),
 agg as (
 select (date_trunc(p_bucket,f.created_at at time zone (select tz from settings)))::date as bucket,
  sum(f.n)::bigint as cnt,sum(f.g) gross,sum(f.fees) fees,sum(f.pts) pts,sum(f.bonus) bonus,
  sum(f.co) co,sum(f.rc) rc,sum(f.ex) ex,sum(f.point_cost) cost,sum(f.owner_fee) owner_fee,sum(f.player_fee) player_fee,sum(f.debit) debit
 from facts f group by 1
 )
 select a.bucket::text,a.cnt,round(a.gross,2),round(a.fees,2),round(a.pts,2),round(a.bonus,2),
  round(a.co,2),round(a.rc,2),round(a.ex,2),round(a.cost,2),
  round(a.gross-a.fees-a.debit-a.ex-a.cost,2),
  round(a.gross-a.fees-a.debit-a.rc-a.ex,2),round(a.owner_fee,2),round(a.player_fee,2),round(a.debit,2)
 from agg a order by a.bucket desc;
end $function$;
revoke all on function public.workspace_report_summary_v2(uuid,text) from public,anon;
grant execute on function public.workspace_report_summary_v2(uuid,text) to authenticated;
create or replace view public.cashouts_visible as select c.id,c.workspace_id,c.player_id,c.game_id,c.provider_id,c.points,c.gross_amount,c.net_paid,c.note,c.created_by,c.created_at,c.review_status,c.review_reason,c.reviewed_by,c.reviewed_at,c.approval_reason,c.fee_rate,c.fee_fixed,c.fee_bearer,c.backend_purchase_rate,
round(c.gross_amount*c.fee_rate/100+c.fee_fixed,2) as processing_fee,
case when c.fee_bearer='owner' then round(c.gross_amount*c.fee_rate/100+c.fee_fixed,2) else 0 end as owner_fee,
case when c.fee_bearer='player' then c.gross_amount-c.net_paid else 0 end as player_fee,
c.gross_amount+case when c.fee_bearer='owner' then round(c.gross_amount*c.fee_rate/100+c.fee_fixed,2) else 0 end as processor_debit
from public.cashouts c where auth.uid() is not null and public.team_access_active(c.workspace_id) and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.workspace_id=c.workspace_id);
