-- Sweep Calculator full-workflow additive database release, 2026-11-14
-- Existing user transactions are preserved. Apply after earlier workspace, cash-out and team migrations.
begin;
alter table public.players add column if not exists bonus_percent numeric(6,2) not null default 0;
alter table public.players drop constraint if exists players_bonus_range;
alter table public.players add constraint players_bonus_range check(bonus_percent between 0 and 100);
create unique index if not exists players_normalized_name_per_workspace on public.players(workspace_id,lower(btrim(regexp_replace(name,'[[:space:]]+',' ','g'))));
alter table public.loads add column if not exists bonus_percent numeric(6,2) not null default 0;
alter table public.loads add column if not exists note text;
alter table public.loads drop constraint if exists loads_bonus_range;
alter table public.loads add constraint loads_bonus_range check(bonus_percent between 0 and 100);
alter table public.workspaces add column if not exists closing_timezone text not null default 'UTC';
alter table public.closings add column if not exists manager_note text;
alter table public.closings add column if not exists review_status text not null default 'approved';
alter table public.closings add column if not exists review_reason text;
alter table public.closings add column if not exists scheduled_cutoff_at timestamptz;
alter table public.closings add column if not exists late_closing boolean not null default false;
alter table public.closings add column if not exists cashout_points numeric;
alter table public.closings add column if not exists reviewed_by uuid;
alter table public.closings add column if not exists reviewed_at timestamptz;
create unique index if not exists unique_backend_daily_cutoff on public.closings(game_id,scheduled_cutoff_at) where scheduled_cutoff_at is not null;

create table if not exists public.load_correction_requests(
 id uuid primary key default gen_random_uuid(),
 workspace_id uuid not null references public.workspaces(id),
 load_id uuid not null references public.loads(id),
 requested_by uuid not null,
 requested_player_id uuid not null references public.players(id),
 requested_game_id uuid not null references public.games(id),
 requested_provider_id uuid not null references public.providers(id),
 requested_payment numeric(16,2) not null check(requested_payment>0),
 requested_note text, reason text not null check(length(btrim(reason))>=3),
 status text not null default 'pending' check(status in('pending','approved','rejected')),
 reviewed_by uuid,reviewed_at timestamptz,review_note text,created_at timestamptz not null default now()
);
create unique index if not exists one_pending_load_correction on public.load_correction_requests(load_id) where status='pending';
create index if not exists load_requests_recent on public.load_correction_requests(workspace_id,created_at desc);
alter table public.load_correction_requests enable row level security;
drop policy if exists load_correction_requests_read on public.load_correction_requests;
create policy load_correction_requests_read on public.load_correction_requests for select to authenticated using
 (public.team_access_active(workspace_id) and (public.is_workspace_manager(workspace_id) or requested_by=auth.uid()));

create table if not exists public.load_correction_audit(
 id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.workspaces(id),
 load_id uuid not null references public.loads(id),actor_id uuid not null,reason text not null,
 old_record jsonb not null,new_record jsonb not null,created_at timestamptz not null default now()
);
create index if not exists load_audit_recent on public.load_correction_audit(workspace_id,created_at desc);
alter table public.load_correction_audit enable row level security;
drop policy if exists load_correction_audit_read on public.load_correction_audit;
create policy load_correction_audit_read on public.load_correction_audit for select to authenticated using
 (public.team_access_active(workspace_id) and public.is_workspace_manager(workspace_id));

create table if not exists public.closing_audit(
 id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.workspaces(id),
 closing_id uuid not null references public.closings(id),actor_id uuid not null,action text not null,
 reason text not null,old_record jsonb not null,new_record jsonb not null,
 created_at timestamptz not null default now()
);
create index if not exists closing_audit_workspace_recent on public.closing_audit(workspace_id,created_at desc);
alter table public.closing_audit enable row level security;
drop policy if exists closing_audit_read on public.closing_audit;
create policy closing_audit_read on public.closing_audit for select to authenticated using
 (public.team_access_active(workspace_id) and public.is_workspace_manager(workspace_id));

create table if not exists public.payment_reconciliations(
 id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.workspaces(id),
 provider_id uuid not null references public.providers(id),period_start timestamptz not null,
 period_end timestamptz not null,actual_net numeric(16,2) not null,
 expected_net numeric(16,2) not null,
 difference numeric(16,2) generated always as(actual_net-expected_net) stored,
 note text not null,created_by uuid not null default auth.uid(),created_at timestamptz not null default now(),
 constraint payment_recon_valid_period check(period_end>period_start),
 constraint payment_recon_note check(length(btrim(note))>=3)
);
alter table public.payment_reconciliations enable row level security;
drop policy if exists "Managers view payment reconciliations" on public.payment_reconciliations;
create policy "Managers view payment reconciliations" on public.payment_reconciliations for select to authenticated
 using(public.is_workspace_manager(workspace_id));
alter table public.payment_reconciliations add column if not exists review_status text not null default 'matched';
alter table public.payment_reconciliations add column if not exists reviewed_by uuid;
alter table public.payment_reconciliations add column if not exists reviewed_at timestamptz;
alter table public.payment_reconciliations add column if not exists review_reason text;
alter table public.payment_reconciliations drop constraint if exists payment_reconciliation_review_status_valid;
alter table public.payment_reconciliations add constraint payment_reconciliation_review_status_valid check
(review_status in ('matched','mismatch','stale','owner_approved'));

create schema if not exists private;

CREATE OR REPLACE FUNCTION private.apply_load_change(p_load uuid, p_player uuid, p_game uuid, p_provider uuid, p_payment numeric, p_note text, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old_load public.loads%rowtype; new_load public.loads%rowtype;
 pr public.players%rowtype; g public.games%rowtype; provider public.providers%rowtype; bonus numeric;
begin
 select * into old_load from public.loads where id=p_load for update;
 if old_load.id is null or p_payment is null or p_payment<=0 or p_payment>100000000 then raise exception 'Invalid load correction';end if;
 select * into pr from public.players where id=p_player and workspace_id=old_load.workspace_id;
 select * into g from public.games where id=p_game and workspace_id=old_load.workspace_id;
 select * into provider from public.providers where id=p_provider and workspace_id=old_load.workspace_id;
 if pr.id is null or g.id is null or provider.id is null then raise exception 'Invalid player, backend or provider';end if;
 bonus:=case when old_load.player_id=p_player and old_load.payment>0 and old_load.bonus_percent=0 and old_load.points<>old_load.payment
             then least(100,greatest(0,round((old_load.points/old_load.payment-1)*100,2)))
             when old_load.player_id=p_player then old_load.bonus_percent else pr.bonus_percent end;
 update public.loads set player_id=p_player,game_id=p_game,provider_id=p_provider,payment=round(p_payment,2),
  points=round(round(p_payment,2)*(1+bonus/100),2),bonus_percent=bonus,
  rate=case when old_load.provider_id=p_provider then old_load.rate else provider.rate end,
  fixed_fee=case when old_load.provider_id=p_provider then old_load.fixed_fee else provider.fixed_fee end,
  purchase_rate=case when old_load.game_id=p_game then old_load.purchase_rate else g.purchase_rate end,
  note=p_note,updated_at=now(),correction_reason=p_reason
 where id=p_load returning * into new_load;
 insert into public.load_correction_audit(workspace_id,load_id,actor_id,reason,old_record,new_record)
 values(old_load.workspace_id,p_load,auth.uid(),p_reason,to_jsonb(old_load),to_jsonb(new_load));
 -- A historical correction reopens any affected closing for review.
 update public.closings c set
  recorded_load_points=(select coalesce(sum(l.points),0) from public.loads l where l.workspace_id=c.workspace_id and l.game_id=c.game_id and l.created_at>c.period_start and l.created_at<=c.period_end),
  difference=c.actual_used_points-(select coalesce(sum(l.points),0) from public.loads l where l.workspace_id=c.workspace_id and l.game_id=c.game_id and l.created_at>c.period_start and l.created_at<=c.period_end),
  review_status='review_required',review_reason='Historical load correction changed closed-period totals'
 where c.workspace_id=old_load.workspace_id and c.actual_used_points is not null
  and c.game_id in(old_load.game_id,p_game) and old_load.created_at>c.period_start and old_load.created_at<=c.period_end;
end $function$;

CREATE OR REPLACE FUNCTION public.record_load(p_player uuid, p_game uuid, p_provider uuid, p_payment numeric, p_note text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare pr public.players%rowtype; g public.games%rowtype; provider public.providers%rowtype; new_id uuid;
begin
 select * into pr from public.players where id=p_player;
 if pr.id is null or not public.team_access_active(pr.workspace_id) or not public.is_workspace_member(pr.workspace_id) then raise exception 'Active team membership required';end if;
 select * into g from public.games where id=p_game and workspace_id=pr.workspace_id;
 select * into provider from public.providers where id=p_provider and workspace_id=pr.workspace_id;
 if g.id is null or provider.id is null then raise exception 'Invalid backend/provider';end if;
 if p_payment is null or p_payment<=0 or p_payment>100000000 then raise exception 'Invalid payment amount';end if;
 insert into public.loads(workspace_id,player_id,game_id,provider_id,payment,points,rate,fixed_fee,purchase_rate,bonus_percent,note,created_by)
 values(pr.workspace_id,p_player,p_game,p_provider,round(p_payment,2),
        round(round(p_payment,2)*(1+pr.bonus_percent/100),2),
        provider.rate,provider.fixed_fee,g.purchase_rate,pr.bonus_percent,nullif(btrim(coalesce(p_note,'')),''),auth.uid())
 returning id into new_id;
 return new_id;
end $function$;

CREATE OR REPLACE FUNCTION public.update_player_bonus(p_player uuid, p_bonus numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare w uuid;
begin
 select workspace_id into w from public.players where id=p_player;
 if w is null or not public.team_access_active(w) or not public.is_workspace_manager(w) then raise exception 'Manager or Owner access required';end if;
 if p_bonus is null or p_bonus<0 or p_bonus>100 then raise exception 'Bonus must be 0 to 100 percent';end if;
 update public.players set bonus_percent=p_bonus where id=p_player;
end $function$;

CREATE OR REPLACE FUNCTION public.submit_load_correction(p_load uuid, p_player uuid, p_game uuid, p_provider uuid, p_payment numeric, p_note text, p_reason text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old_load public.loads%rowtype; actor_role text;
begin
 select * into old_load from public.loads where id=p_load for update;
 if old_load.id is null or not public.team_access_active(old_load.workspace_id) then raise exception 'Load missing or account disabled';end if;
 select role into actor_role from public.memberships where workspace_id=old_load.workspace_id and user_id=auth.uid();
 if actor_role is null then raise exception 'Not a workspace member';end if;
 if actor_role='worker' and old_load.created_by<>auth.uid() then raise exception 'Only your own loads may be corrected';end if;
 if p_payment is null or p_payment<=0 or p_payment>100000000 or length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Valid amount and reason required';end if;
 if not exists(select 1 from public.players p where p.id=p_player and p.workspace_id=old_load.workspace_id)
 or not exists(select 1 from public.games g where g.id=p_game and g.workspace_id=old_load.workspace_id)
 or not exists(select 1 from public.providers p where p.id=p_provider and p.workspace_id=old_load.workspace_id)
 then raise exception 'Invalid player/backend/provider';end if;
 if actor_role in ('owner','manager') or now()<=old_load.created_at+interval '15 minutes' then
   perform private.apply_load_change(p_load,p_player,p_game,p_provider,p_payment,p_note,p_reason);
   return 'applied';
 end if;
 insert into public.load_correction_requests(workspace_id,load_id,requested_by,requested_player_id,requested_game_id,requested_provider_id,requested_payment,requested_note,reason)
 values(old_load.workspace_id,p_load,auth.uid(),p_player,p_game,p_provider,p_payment,p_note,p_reason);
 return 'pending_approval';
end $function$;

CREATE OR REPLACE FUNCTION public.review_load_correction(p_request uuid, p_approve boolean, p_review_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.load_correction_requests%rowtype;
begin
 select * into r from public.load_correction_requests where id=p_request for update;
 if r.id is null or not public.team_access_active(r.workspace_id) or not public.is_workspace_manager(r.workspace_id) then raise exception 'Manager/Owner required';end if;
 if r.status<>'pending' then raise exception 'Already reviewed';end if;
 if length(btrim(coalesce(p_review_note,'')))<3 then raise exception 'Review notes required';end if;
 if p_approve then
   perform private.apply_load_change(r.load_id,r.requested_player_id,r.requested_game_id,r.requested_provider_id,r.requested_payment,r.requested_note,r.reason||' | Approved: '||p_review_note);
 end if;
 update public.load_correction_requests set status=case when p_approve then 'approved' else 'rejected' end,
 reviewed_by=auth.uid(),reviewed_at=now(),review_note=p_review_note where id=p_request;
end $function$;

CREATE OR REPLACE FUNCTION public.update_workspace_schedule(p_workspace uuid, p_cutoff time without time zone, p_timezone text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if p_cutoff is null or p_timezone is null or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_timezone)
 then raise exception 'Valid time and IANA timezone required';end if;
 if not public.team_access_active(p_workspace) or not exists(select 1 from public.memberships m where m.workspace_id=p_workspace and m.user_id=auth.uid() and m.role='owner')
 then raise exception 'Owner access required';end if;
 update public.workspaces set closing_time=p_cutoff,closing_timezone=p_timezone where id=p_workspace;
end $function$;

CREATE OR REPLACE FUNCTION public.finalize_backend_closing(p_game uuid, p_balance numeric, p_note text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare w uuid; prev public.closings%rowtype; ws public.workspaces%rowtype;
 local_clock timestamp; scheduled_at timestamptz; measured_at timestamptz;
 rp numeric; lp numeric; cp numeric; used numeric; diff numeric; late boolean; review text; id_out uuid;
begin
 select g.workspace_id into w from public.games g where g.id=p_game;
 if w is null or not public.team_access_active(w) or not exists(
  select 1 from public.memberships m where m.workspace_id=w and m.user_id=auth.uid() and m.role='manager')
 then raise exception 'Only an active Manager can finalize closing';end if;
 if p_balance is null or p_balance<0 or p_balance>100000000000 then raise exception 'Invalid backend balance';end if;
 if length(btrim(coalesce(p_note,'')))<3 then raise exception 'Manager notes required';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_game::text,0));
 select * into ws from public.workspaces where id=w;
 select * into prev from public.closings c where c.game_id=p_game order by c.created_at desc,c.id desc limit 1;
 measured_at:=now();
 if prev.id is null then
  insert into public.closings(workspace_id,game_id,balance,created_by,period_start,period_end,manager_note,review_status)
  values(w,p_game,p_balance,auth.uid(),measured_at,measured_at,p_note,'approved') returning id into id_out;
  return id_out;
 end if;
 local_clock:=measured_at at time zone ws.closing_timezone;
 scheduled_at:=(date_trunc('day',local_clock)+ws.closing_time) at time zone ws.closing_timezone;
 if scheduled_at>measured_at then
  scheduled_at:=(date_trunc('day',local_clock)-interval '1 day'+ws.closing_time) at time zone ws.closing_timezone;
 end if;
 if scheduled_at<=coalesce(prev.period_end,prev.created_at) then
  raise exception 'Next daily cutoff has not been reached yet';end if;
 late:=measured_at>scheduled_at+interval '30 minutes';
 select coalesce(sum(r.points),0) into rp from public.reloads r
  where r.workspace_id=w and r.game_id=p_game and r.created_at>coalesce(prev.period_end,prev.created_at) and r.created_at<=measured_at;
 select coalesce(sum(l.points),0) into lp from public.loads l
  where l.workspace_id=w and l.game_id=p_game and l.created_at>coalesce(prev.period_end,prev.created_at) and l.created_at<=measured_at;
 select coalesce(sum(x.points),0) into cp from public.cashouts x
  where x.workspace_id=w and x.game_id=p_game and x.created_at>coalesce(prev.period_end,prev.created_at) and x.created_at<=measured_at;
 used:=prev.balance+rp+cp-p_balance;
 diff:=used-lp;
 review:=case when abs(diff)>0.001 and late then 'Late closing and backend mismatch'
              when abs(diff)>0.001 then 'Backend balance mismatch'
              when late then 'Closing submitted beyond 30-minute grace period'
              else null end;
 if review is not null and length(btrim(p_note))<10 then raise exception 'Please explain late closing or mismatch (at least 10 characters)';end if;
 insert into public.closings(
  workspace_id,game_id,balance,created_by,period_start,period_end,previous_balance,reload_points,recorded_load_points,
  cashout_points,actual_used_points,difference,manager_note,scheduled_cutoff_at,late_closing,review_status,review_reason)
 values(w,p_game,p_balance,auth.uid(),coalesce(prev.period_end,prev.created_at),measured_at,prev.balance,rp,lp,
  cp,used,diff,p_note,scheduled_at,late,case when review is null then 'approved' else 'review_required' end,review)
 returning id into id_out;
 return id_out;
end $function$;

CREATE OR REPLACE FUNCTION public.review_backend_closing(p_closing uuid, p_corrected_balance numeric, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old_row public.closings%rowtype; new_row public.closings%rowtype; latest_id uuid;
begin
 select * into old_row from public.closings where id=p_closing for update;
 if old_row.id is null or not public.team_access_active(old_row.workspace_id) or not exists(
  select 1 from public.memberships m where m.workspace_id=old_row.workspace_id and m.user_id=auth.uid() and m.role='owner')
 then raise exception 'Owner access required';end if;
 if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Review reason required';end if;
 if p_corrected_balance is not null then
  if p_corrected_balance<0 then raise exception 'Invalid balance';end if;
  select id into latest_id from public.closings where game_id=old_row.game_id order by created_at desc,id desc limit 1;
  if latest_id<>p_closing then raise exception 'Only latest backend closing can be corrected';end if;
  update public.closings set balance=p_corrected_balance,
   actual_used_points=case when previous_balance is null then null else previous_balance+coalesce(reload_points,0)+coalesce(cashout_points,0)-p_corrected_balance end,
   difference=case when previous_balance is null then null else previous_balance+coalesce(reload_points,0)+coalesce(cashout_points,0)-p_corrected_balance-coalesce(recorded_load_points,0) end,
   review_status='approved',review_reason=p_reason,reviewed_by=auth.uid(),reviewed_at=now()
  where id=p_closing returning * into new_row;
 else
  if old_row.review_status<>'review_required' then raise exception 'Only pending closings can be approved';end if;
  update public.closings set review_status='approved',review_reason=p_reason,reviewed_by=auth.uid(),reviewed_at=now()
  where id=p_closing returning * into new_row;
 end if;
 insert into public.closing_audit(workspace_id,closing_id,actor_id,action,reason,old_record,new_record)
 values(old_row.workspace_id,p_closing,auth.uid(),case when p_corrected_balance is null then 'approved' else 'corrected' end,
        p_reason,to_jsonb(old_row),to_jsonb(new_row));
end $function$;

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
 select c.created_at,0::bigint,0::numeric,case when c.fee_bearer='owner' then round(c.gross_amount*c.fee_rate/100+c.fee_fixed,2) else 0 end,0::numeric,0::numeric,c.net_paid,0::numeric,0::numeric,
  -(c.points*coalesce(g.purchase_rate,0)/100)
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

CREATE OR REPLACE FUNCTION public.workspace_loader_performance(p_workspace uuid)
 RETURNS TABLE(worker_id uuid, login_label text, role_label text, players_added bigint, loads_count bigint, gross numeric, points numeric, bonus numeric, cashouts_count bigint, cashouts_paid numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not public.team_access_active(p_workspace) or not public.is_workspace_manager(p_workspace) then raise exception 'Manager/Owner required';end if;
 return query
 select m.user_id,coalesce(t.login_id,'User '||left(m.user_id::text,8)),m.role,
  (select count(*) from public.players p where p.workspace_id=p_workspace and p.created_by=m.user_id),
  (select count(*) from public.loads l where l.workspace_id=p_workspace and l.created_by=m.user_id),
  (select coalesce(sum(l.payment),0) from public.loads l where l.workspace_id=p_workspace and l.created_by=m.user_id),
  (select coalesce(sum(l.points),0) from public.loads l where l.workspace_id=p_workspace and l.created_by=m.user_id),
  (select coalesce(sum(l.points-l.payment),0) from public.loads l where l.workspace_id=p_workspace and l.created_by=m.user_id),
  (select count(*) from public.cashouts c where c.workspace_id=p_workspace and c.created_by=m.user_id),
  (select coalesce(sum(c.net_paid),0) from public.cashouts c where c.workspace_id=p_workspace and c.created_by=m.user_id)
 from public.memberships m left join public.team_accounts t on t.user_id=m.user_id and t.workspace_id=m.workspace_id
 where m.workspace_id=p_workspace order by m.role,t.login_id;
end $function$;

CREATE OR REPLACE FUNCTION public.backend_live_ticker(p_workspace uuid)
 RETURNS TABLE(game_id uuid, game_name text, last_closing_at timestamp with time zone, starting_balance numeric, points_reloaded numeric, points_loaded numeric, cashout_credit numeric, estimated_available numeric, needs_review boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if not public.team_access_active(p_workspace) or not public.is_workspace_manager(p_workspace) then raise exception 'Manager/Owner required';end if;
 return query
 select g.id,g.name,c.period_end,c.balance,
  (select coalesce(sum(r.points),0) from public.reloads r where r.game_id=g.id and (c.period_end is null or r.created_at>c.period_end)),
  (select coalesce(sum(l.points),0) from public.loads l where l.game_id=g.id and (c.period_end is null or l.created_at>c.period_end)),
  (select coalesce(sum(x.points),0) from public.cashouts x where x.game_id=g.id and (c.period_end is null or x.created_at>c.period_end)),
  case when c.id is null then null else c.balance+
   (select coalesce(sum(r.points),0) from public.reloads r where r.game_id=g.id and r.created_at>c.period_end)-
   (select coalesce(sum(l.points),0) from public.loads l where l.game_id=g.id and l.created_at>c.period_end)+
   (select coalesce(sum(x.points),0) from public.cashouts x where x.game_id=g.id and x.created_at>c.period_end) end,
  exists(select 1 from public.closings pending where pending.game_id=g.id and pending.review_status='review_required')
 from public.games g
 left join lateral (select * from public.closings c0 where c0.game_id=g.id order by c0.created_at desc limit 1)c on true
 where g.workspace_id=p_workspace order by g.name;
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
 expected:=expected-coalesce((select sum(c.net_paid+case when c.fee_bearer='owner' then round(c.gross_amount*c.fee_rate/100+c.fee_fixed,2) else 0 end) from public.cashouts c
 where c.provider_id=p_provider and c.workspace_id=w and c.created_at>=p_start and c.created_at<p_end),0);
 insert into public.payment_reconciliations(workspace_id,provider_id,period_start,period_end,actual_net,expected_net,note,created_by,review_status)
 values(w,p_provider,p_start,p_end,p_actual,round(expected,2),p_note,auth.uid(),
  case when abs(round(expected,2)-p_actual)>0.01 then 'mismatch' else 'matched' end)
 returning id into rid;
 return rid;
end $function$;

CREATE OR REPLACE FUNCTION public.review_payment_reconciliation(p_reconciliation uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare record public.payment_reconciliations%rowtype;
begin
 select * into record from public.payment_reconciliations where id=p_reconciliation for update;
 if record.id is null or not public.team_access_active(record.workspace_id) or not exists(
 select 1 from public.memberships m where m.workspace_id=record.workspace_id and m.user_id=auth.uid() and m.role='owner')
 then raise exception 'Owner required';end if;
 if record.review_status<>'mismatch' then raise exception 'Only mismatch items can be approved';end if;
 if length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Approval reason required';end if;
 update public.payment_reconciliations set review_status='owner_approved',review_reason=p_reason,
 reviewed_by=auth.uid(),reviewed_at=now() where id=p_reconciliation;
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
  if old.provider_id is not distinct from new.provider_id and old.net_paid is not distinct from new.net_paid then return new;end if;
 end if;
 changed_at:=old.created_at;
 update public.payment_reconciliations r set review_status='stale',review_reason='Financial transaction corrected; reconcile this provider and period again'
 where r.workspace_id=old.workspace_id and (r.provider_id=old.provider_id or r.provider_id=new.provider_id)
 and changed_at>=r.period_start and changed_at<r.period_end and r.review_status<>'stale';
 return new;
end $function$;

CREATE OR REPLACE FUNCTION public.recalculate_closings_after_cashout_correction()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if old.points is not distinct from new.points then return new;end if;
 update public.closings c set
   cashout_points=(select coalesce(sum(x.points),0) from public.cashouts x where x.game_id=c.game_id and x.workspace_id=c.workspace_id and x.created_at>c.period_start and x.created_at<=c.period_end),
   actual_used_points=c.previous_balance+coalesce(c.reload_points,0)+
    (select coalesce(sum(x.points),0) from public.cashouts x where x.game_id=c.game_id and x.workspace_id=c.workspace_id and x.created_at>c.period_start and x.created_at<=c.period_end)-c.balance,
   difference=c.previous_balance+coalesce(c.reload_points,0)+
    (select coalesce(sum(x.points),0) from public.cashouts x where x.game_id=c.game_id and x.workspace_id=c.workspace_id and x.created_at>c.period_start and x.created_at<=c.period_end)
    -c.balance-coalesce(c.recorded_load_points,0),
   review_status='review_required',review_reason='Historical cash-out credit correction changed backend totals'
 where c.workspace_id=new.workspace_id and c.game_id=new.game_id and c.previous_balance is not null
 and new.created_at>c.period_start and new.created_at<=c.period_end;
 return new;
end $function$;


-- RPC execution permissions (the internal apply helper is never directly callable by clients).
revoke all on function private.apply_load_change(uuid,uuid,uuid,uuid,numeric,text,text) from public,anon,authenticated;
revoke all on function public.finalize_backend_closing(uuid,numeric) from public,anon,authenticated;
revoke insert,update,delete on public.loads from public,anon,authenticated;
drop policy if exists loads_insert on public.loads;
grant select on public.load_correction_requests,public.load_correction_audit,public.closing_audit,public.payment_reconciliations to authenticated;
revoke all on function public.record_load(uuid,uuid,uuid,numeric,text) from public;
revoke all on function public.update_player_bonus(uuid,numeric) from public;
revoke all on function public.submit_load_correction(uuid,uuid,uuid,uuid,numeric,text,text) from public;
revoke all on function public.review_load_correction(uuid,boolean,text) from public;
revoke all on function public.update_workspace_schedule(uuid,time,text) from public;
revoke all on function public.review_backend_closing(uuid,numeric,text) from public;
revoke all on function public.workspace_report_summary(uuid,text) from public;
revoke all on function public.workspace_loader_performance(uuid) from public;
revoke all on function public.backend_live_ticker(uuid) from public;
revoke all on function public.record_payment_reconciliation(uuid,timestamptz,timestamptz,numeric,text) from public;
revoke all on function public.review_payment_reconciliation(uuid,text) from public;
revoke all on function public.mark_payment_settlements_stale() from public,anon,authenticated;
revoke all on function public.recalculate_closings_after_cashout_correction() from public,anon,authenticated;
grant execute on function public.record_load(uuid,uuid,uuid,numeric,text),
 public.update_player_bonus(uuid,numeric),
 public.submit_load_correction(uuid,uuid,uuid,uuid,numeric,text,text),
 public.review_load_correction(uuid,boolean,text),
 public.update_workspace_schedule(uuid,time,text),
 public.finalize_backend_closing(uuid,numeric,text),
 public.review_backend_closing(uuid,numeric,text),
 public.workspace_report_summary(uuid,text),
 public.workspace_loader_performance(uuid),
 public.backend_live_ticker(uuid),
 public.record_payment_reconciliation(uuid,timestamptz,timestamptz,numeric,text),
 public.review_payment_reconciliation(uuid,text) to authenticated;
drop trigger if exists payment_reconciliation_stale_on_load_change on public.loads;
create trigger payment_reconciliation_stale_on_load_change after update on public.loads
 for each row execute function public.mark_payment_settlements_stale();
drop trigger if exists payment_reconciliation_stale_on_cashout_change on public.cashouts;
create trigger payment_reconciliation_stale_on_cashout_change after update on public.cashouts
 for each row execute function public.mark_payment_settlements_stale();
drop trigger if exists closing_recalculate_on_cashout_point_edit on public.cashouts;
create trigger closing_recalculate_on_cashout_point_edit after update of points on public.cashouts
 for each row execute function public.recalculate_closings_after_cashout_correction();
do $$
declare t text;
begin
 foreach t in array array['cashouts','cashout_notifications','closings','reloads','payment_reconciliations','load_correction_requests','cashout_audit','closing_audit']
 loop
  if not exists(select 1 from pg_catalog.pg_publication_tables p where p.pubname='supabase_realtime' and p.schemaname='public' and p.tablename=t)
  then execute format('alter publication supabase_realtime add table public.%I',t);end if;
 end loop;
end $$;
commit;
