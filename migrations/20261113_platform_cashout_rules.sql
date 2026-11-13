create table if not exists public.platform_cashout_rules (
 workspace_id uuid primary key references public.workspaces(id) on delete cascade,
 min_multiplier numeric not null default 3 check(min_multiplier>=0),
 max_points numeric check(max_points>0),
 fee_rate numeric not null default 0 check(fee_rate between 0 and 100),
 fee_fixed numeric not null default 0 check(fee_fixed>=0),
 fee_bearer text not null default 'player' check(fee_bearer in ('player','owner'))
);
alter table public.platform_cashout_rules enable row level security;
create policy platform_cashout_owner_read on public.platform_cashout_rules for select to authenticated using(
 public.team_access_active(workspace_id) and exists(select 1 from public.memberships m where m.workspace_id=platform_cashout_rules.workspace_id and m.user_id=auth.uid() and m.role='owner')
);
insert into public.platform_cashout_rules(workspace_id,min_multiplier,max_points,fee_rate,fee_fixed,fee_bearer)
select distinct on (workspace_id) workspace_id,min_multiplier,max_points,fee_rate,fee_fixed,fee_bearer
from public.cashout_rules order by workspace_id,game_id
on conflict(workspace_id) do nothing;
create or replace function public.update_platform_cashout_rules(p_workspace uuid,p_min_multiplier numeric,p_max_points numeric,p_fee_rate numeric,p_fee_fixed numeric,p_fee_bearer text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.team_access_active(p_workspace) or not exists(select 1 from public.memberships m where m.workspace_id=p_workspace and m.user_id=auth.uid() and m.role='owner') then raise exception 'Owner access required'; end if;
 if p_min_multiplier is null or p_min_multiplier<0 or p_max_points is null or p_max_points<0 or p_fee_rate is null or p_fee_rate<0 or p_fee_rate>100 or p_fee_fixed is null or p_fee_fixed<0 or p_fee_bearer is null or p_fee_bearer not in ('owner','player') then raise exception 'Invalid cash-out rule'; end if;
 insert into public.platform_cashout_rules(workspace_id,min_multiplier,max_points,fee_rate,fee_fixed,fee_bearer)
 values(p_workspace,p_min_multiplier,nullif(p_max_points,0),p_fee_rate,p_fee_fixed,p_fee_bearer)
 on conflict(workspace_id) do update set min_multiplier=excluded.min_multiplier,max_points=excluded.max_points,fee_rate=excluded.fee_rate,fee_fixed=excluded.fee_fixed,fee_bearer=excluded.fee_bearer;
end $$;
revoke all on function public.update_platform_cashout_rules(uuid,numeric,numeric,numeric,numeric,text) from public;
grant execute on function public.update_platform_cashout_rules(uuid,numeric,numeric,numeric,numeric,text) to authenticated;
create or replace function public.record_cashout(p_player uuid,p_game uuid,p_provider uuid,p_points numeric,p_gross numeric,p_note text default '')
returns uuid language plpgsql security definer set search_path='' as $$
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
 insert into public.cashouts(workspace_id,player_id,game_id,provider_id,points,gross_amount,fee_rate,fee_fixed,fee_bearer,net_paid,note,review_status,review_reason)
 values(w,p_player,p_game,p_provider,p_points,p_gross,coalesce(rules.fee_rate,0),coalesce(rules.fee_fixed,0),coalesce(rules.fee_bearer,'player'),paid,coalesce(p_note,''),case when suspicious then 'review_required' else 'clear' end,why) returning * into r;
 insert into public.cashout_audit(cashout_id,workspace_id,action,reason,new_record) values(r.id,w,'created','Cash-out recorded',to_jsonb(r));
 if suspicious then insert into public.cashout_notifications(workspace_id,cashout_id,kind) values(w,r.id,'review_required'); end if;
 return r.id;
end $$;
drop function if exists public.update_cashout_rules(uuid,numeric,numeric,numeric,numeric,text);
revoke all on public.cashout_rules from anon,authenticated;
