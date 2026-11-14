-- Cash-Out backend rate snapshot for defensible historical profit calculations.
-- Requires the cash-out workflow and full-workflow migration.
begin;
alter table public.cashouts add column if not exists backend_purchase_rate numeric;
update public.cashouts c set backend_purchase_rate=g.purchase_rate
from public.games g where g.id=c.game_id and c.backend_purchase_rate is null;

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
 minimum:=coalesce(last_points,0)*coalesce(rules.min_multiplier,3);
 fee:=round((p_gross*coalesce(rules.fee_rate,0)/100+coalesce(rules.fee_fixed,0))::numeric,2);
 paid:=case when coalesce(rules.fee_bearer,'player')='player' then p_gross-fee else p_gross end;
 if paid<0 then raise exception 'Cash-out fee exceeds payout'; end if;
 suspicious:=last_points is null or p_points<minimum or (rules.max_points is not null and p_points>rules.max_points);
 why:=case when last_points is null then 'No prior load found for this player/backend' when p_points<minimum then 'Redeemed points below configured minimum' when rules.max_points is not null and p_points>rules.max_points then 'Redeemed points exceed configured maximum' else null end;
 insert into public.cashouts(workspace_id,player_id,game_id,provider_id,points,gross_amount,fee_rate,fee_fixed,fee_bearer,net_paid,note,review_status,review_reason,backend_purchase_rate)
 values(w,p_player,p_game,p_provider,p_points,p_gross,coalesce(rules.fee_rate,0),coalesce(rules.fee_fixed,0),coalesce(rules.fee_bearer,'player'),paid,coalesce(p_note,''),case when suspicious then 'review_required' else 'clear' end,why,g.purchase_rate) returning * into r;
 insert into public.cashout_audit(cashout_id,workspace_id,action,reason,new_record) values(r.id,w,'created','Cash-out recorded',to_jsonb(r));
 if suspicious then insert into public.cashout_notifications(workspace_id,cashout_id,kind) values(w,r.id,'review_required'); end if;
 return r.id;
end $function$


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
end $function$



create or replace view public.cashouts_visible as
select c.id,c.workspace_id,c.player_id,c.game_id,c.provider_id,c.points,c.gross_amount,c.net_paid,c.note,
c.created_by,c.created_at,c.review_status,c.review_reason,c.reviewed_by,c.reviewed_at,c.approval_reason,
c.fee_rate,c.fee_fixed,c.fee_bearer,c.backend_purchase_rate
from public.cashouts c
where auth.uid() is not null and public.team_access_active(c.workspace_id)
and exists(select 1 from public.memberships m where m.user_id=auth.uid() and m.workspace_id=c.workspace_id);
revoke insert,update,delete on public.cashouts_visible from public,anon,authenticated;
grant select on public.cashouts_visible to authenticated;
commit;
