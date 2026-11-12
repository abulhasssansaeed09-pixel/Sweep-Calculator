-- Cash-out workflow v1: additive schema; apply only after staging review.
-- Owner-controlled per-backend rules. Existing games default to 3x minimum, unlimited maximum, player bears fee.
alter table public.games add column if not exists cashout_min_multiplier numeric not null default 3 check(cashout_min_multiplier>=0);
alter table public.games add column if not exists cashout_max_points numeric check(cashout_max_points>0);
alter table public.games add column if not exists cashout_fee_rate numeric not null default 0 check(cashout_fee_rate between 0 and 100);
alter table public.games add column if not exists cashout_fee_fixed numeric not null default 0 check(cashout_fee_fixed>=0);
alter table public.games add column if not exists cashout_fee_bearer text not null default 'player' check(cashout_fee_bearer in ('player','owner'));
create table if not exists public.cashouts (
 id uuid primary key default gen_random_uuid(),
 workspace_id uuid not null references public.workspaces(id),
 player_id uuid not null references public.players(id),
 game_id uuid not null references public.games(id),
 provider_id uuid not null references public.providers(id),
 points numeric not null check(points>0),
 gross_amount numeric not null check(gross_amount>0),
 fee_rate numeric not null check(fee_rate between 0 and 100),
 fee_fixed numeric not null default 0 check(fee_fixed>=0),
 fee_bearer text not null check(fee_bearer in ('player','owner')),
 net_paid numeric not null check(net_paid>=0),
 note text not null default '',
 created_by uuid not null default auth.uid() references auth.users(id),
 created_at timestamptz not null default now(),
 review_status text not null default 'clear' check(review_status in ('clear','review_required','owner_approved')),
 review_reason text,
 reviewed_by uuid references auth.users(id),
 reviewed_at timestamptz,
 approval_reason text,
 constraint cashout_amount_math check(abs(net_paid - (case when fee_bearer='player' then gross_amount - round(gross_amount*fee_rate/100+fee_fixed,2) else gross_amount end)) < 0.011)
);
create index if not exists cashouts_workspace_created_idx on public.cashouts(workspace_id,created_at desc);
create index if not exists cashouts_player_created_idx on public.cashouts(player_id,created_at desc);
create table if not exists public.cashout_notifications (
 id uuid primary key default gen_random_uuid(),
 workspace_id uuid not null references public.workspaces(id),
 cashout_id uuid not null references public.cashouts(id),
 kind text not null check(kind in ('review_required','owner_approved')),
 created_at timestamptz not null default now(),
 unique(cashout_id,kind)
);
create table if not exists public.cashout_audit (
 id uuid primary key default gen_random_uuid(),
 cashout_id uuid not null references public.cashouts(id),
 workspace_id uuid not null references public.workspaces(id),
 actor_id uuid not null default auth.uid() references auth.users(id),
 action text not null,
 reason text not null,
 old_record jsonb,
 new_record jsonb,
 created_at timestamptz not null default now()
);
alter table public.cashouts enable row level security;
alter table public.cashout_audit enable row level security;
alter table public.cashout_notifications enable row level security;
create policy cashout_notifications_read on public.cashout_notifications for select to authenticated
 using(exists(select 1 from public.memberships m where m.workspace_id=cashout_notifications.workspace_id and m.user_id=auth.uid() and m.role in ('owner','manager')));
drop policy if exists cashouts_read on public.cashouts;
create policy cashouts_read on public.cashouts for select to authenticated
 using(exists(select 1 from public.memberships m where m.workspace_id=cashouts.workspace_id and m.user_id=auth.uid()));
drop policy if exists cashout_audit_read on public.cashout_audit;
create policy cashout_audit_read on public.cashout_audit for select to authenticated
 using(exists(select 1 from public.memberships m where m.workspace_id=cashout_audit.workspace_id and m.user_id=auth.uid() and m.role in ('owner','manager')));
-- No direct INSERT/UPDATE/DELETE policies. All writes go through controlled RPCs.
create or replace function public.record_cashout(p_player uuid,p_game uuid,p_provider uuid,p_points numeric,p_gross numeric,p_note text default '')
returns uuid language plpgsql security definer set search_path='' as $$
declare w uuid; p public.providers%rowtype; g public.games%rowtype; r public.cashouts%rowtype; last_points numeric; minimum numeric; fee numeric; paid numeric; suspicious boolean; why text;
begin
 select m.workspace_id into w from public.memberships m where m.user_id=auth.uid() order by m.created_at limit 1;
 if w is null then raise exception 'Not a workspace member'; end if;
 if not exists(select 1 from public.players x where x.id=p_player and x.workspace_id=w) then raise exception 'Invalid player'; end if;
 select * into g from public.games where id=p_game and workspace_id=w;
 select * into p from public.providers where id=p_provider and workspace_id=w;
 if g.id is null or p.id is null or p_points<=0 or p_gross<=0 then raise exception 'Invalid cash-out details'; end if;
 select l.points into last_points from public.loads l where l.workspace_id=w and l.player_id=p_player and l.game_id=p_game order by l.created_at desc limit 1;
 minimum:=coalesce(last_points,0)*g.cashout_min_multiplier;
 fee:=round((p_gross*g.cashout_fee_rate/100+g.cashout_fee_fixed)::numeric,2);
 paid:=case when g.cashout_fee_bearer='player' then p_gross-fee else p_gross end;
 if paid<0 then raise exception 'Cash-out fee exceeds payout'; end if;
 suspicious:=last_points is null or p_points<minimum or (g.cashout_max_points is not null and p_points>g.cashout_max_points);
 why:=case when last_points is null then 'No prior load found for this player/backend' when p_points<minimum then 'Redeemed points below configured minimum' when g.cashout_max_points is not null and p_points>g.cashout_max_points then 'Redeemed points exceed configured maximum' else null end;
 insert into public.cashouts(workspace_id,player_id,game_id,provider_id,points,gross_amount,fee_rate,fee_fixed,fee_bearer,net_paid,note,review_status,review_reason)
 values(w,p_player,p_game,p_provider,p_points,p_gross,g.cashout_fee_rate,g.cashout_fee_fixed,g.cashout_fee_bearer,paid,coalesce(p_note,''),
 case when suspicious then 'review_required' else 'clear' end,why)
 returning * into r;
 insert into public.cashout_audit(cashout_id,workspace_id,action,reason,new_record)
 values(r.id,w,'created','Cash-out recorded',to_jsonb(r));
 if suspicious then insert into public.cashout_notifications(workspace_id,cashout_id,kind) values(w,r.id,'review_required'); end if;
 return r.id;
end $$;
revoke all on function public.record_cashout(uuid,uuid,uuid,numeric,numeric,text) from public;
grant execute on function public.record_cashout(uuid,uuid,uuid,numeric,numeric,text) to authenticated;
create or replace function public.approve_cashout(p_cashout uuid,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
declare r public.cashouts%rowtype;
begin
 if length(trim(coalesce(p_reason,'')))<3 then raise exception 'Approval reason required'; end if;
 select * into r from public.cashouts where id=p_cashout for update;
 if r.id is null or not exists(select 1 from public.memberships m where m.workspace_id=r.workspace_id and m.user_id=auth.uid() and m.role='owner') then raise exception 'Owner access required'; end if;
 if r.review_status<>'review_required' then raise exception 'Cash-out is not pending review'; end if;
 update public.cashouts set review_status='owner_approved',reviewed_by=auth.uid(),reviewed_at=now(),approval_reason=p_reason where id=p_cashout;
 insert into public.cashout_audit(cashout_id,workspace_id,action,reason,old_record,new_record)
 select r.id,r.workspace_id,'owner_approved',p_reason,to_jsonb(r),to_jsonb(c) from public.cashouts c where c.id=r.id;
 insert into public.cashout_notifications(workspace_id,cashout_id,kind) values(r.workspace_id,r.id,'owner_approved');
end $$;
revoke all on function public.approve_cashout(uuid,text) from public;
grant execute on function public.approve_cashout(uuid,text) to authenticated;
