-- Supersedes any earlier player-level default bonus implementation.
-- This migration keeps all historical players and loads, while removing all player bonus settings.
alter table public.load_correction_requests add column if not exists requested_bonus_percent numeric;
update public.load_correction_requests r set requested_bonus_percent=
 case when l.payment>0 and l.bonus_percent=0 and l.points<>l.payment
 then greatest(0,round((l.points/l.payment-1)*100,2))
 else l.bonus_percent end
from public.loads l where l.id=r.load_id and r.requested_bonus_percent is null;
alter table public.load_correction_requests alter column requested_bonus_percent set not null;
alter table public.load_correction_requests drop constraint if exists load_requested_bonus_range;
alter table public.load_correction_requests add constraint load_requested_bonus_range check(requested_bonus_percent between 0 and 1000);
alter table public.loads alter column bonus_percent drop default;
alter table public.loads drop constraint if exists loads_bonus_range;
alter table public.loads add constraint loads_bonus_range check(bonus_percent between 0 and 1000);

-- Server RPCs now REQUIRE an explicit bonus for each load. No default argument is offered.

CREATE OR REPLACE FUNCTION private.apply_load_change(p_load uuid, p_player uuid, p_game uuid, p_provider uuid, p_payment numeric, p_note text, p_reason text, p_bonus numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare old_load public.loads%rowtype; new_load public.loads%rowtype;
 pr public.players%rowtype; g public.games%rowtype; provider public.providers%rowtype;
begin
 select * into old_load from public.loads where id=p_load for update;
 if old_load.id is null or p_payment is null or p_payment<=0 or p_payment>100000000 then raise exception 'Invalid load correction';end if;
 if p_bonus is null or p_bonus<0 or p_bonus>1000 then raise exception 'Valid transaction bonus required';end if;
 select * into pr from public.players where id=p_player and workspace_id=old_load.workspace_id;
 select * into g from public.games where id=p_game and workspace_id=old_load.workspace_id;
 select * into provider from public.providers where id=p_provider and workspace_id=old_load.workspace_id;
 if pr.id is null or g.id is null or provider.id is null then raise exception 'Invalid player, backend or provider';end if;
 update public.loads set player_id=p_player,game_id=p_game,provider_id=p_provider,payment=round(p_payment,2),
 points=round(round(p_payment,2)*(1+p_bonus/100),2),bonus_percent=p_bonus,
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
end $function$

CREATE OR REPLACE FUNCTION public.record_load(p_player uuid, p_game uuid, p_provider uuid, p_payment numeric, p_note text, p_bonus numeric)
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
 if g.id is null or provider.id is null then raise exception 'Invalid backend/provider';end if;
 if p_payment is null or p_payment<=0 or p_payment>100000000 then raise exception 'Invalid payment amount';end if;
 if p_bonus is null or p_bonus<0 or p_bonus>1000 then raise exception 'Enter bonus percent for this load (0 to 1000)';end if;
 insert into public.loads(workspace_id,player_id,game_id,provider_id,payment,points,rate,fixed_fee,purchase_rate,bonus_percent,note,created_by)
 values(pr.workspace_id,p_player,p_game,p_provider,round(p_payment,2),
 round(round(p_payment,2)*(1+p_bonus/100),2),
 provider.rate,provider.fixed_fee,g.purchase_rate,p_bonus,nullif(btrim(coalesce(p_note,'')),''),auth.uid())
 returning id into new_id;
 return new_id;
end $function$

CREATE OR REPLACE FUNCTION public.review_load_correction(p_request uuid, p_approve boolean, p_review_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r public.load_correction_requests%rowtype;
begin
 select * into r from public.load_correction_requests where id=p_request for update;
 if r.id is null or not public.team_access_active(r.workspace_id) or not public.is_workspace_manager(r.workspace_id)
 then raise exception 'Manager/Owner required';end if;
 if r.status<>'pending' then raise exception 'Already reviewed';end if;
 if length(btrim(coalesce(p_review_note,'')))<3 then raise exception 'Review notes required';end if;
 if p_approve then
  perform private.apply_load_change(r.load_id,r.requested_player_id,r.requested_game_id,r.requested_provider_id,r.requested_payment,r.requested_note,r.reason||' | Approved: '||p_review_note,r.requested_bonus_percent);
 end if;
 update public.load_correction_requests set status=case when p_approve then 'approved' else 'rejected' end,
 reviewed_by=auth.uid(),reviewed_at=now(),review_note=p_review_note where id=p_request;
end $function$

CREATE OR REPLACE FUNCTION public.submit_load_correction(p_load uuid, p_player uuid, p_game uuid, p_provider uuid, p_payment numeric, p_note text, p_reason text, p_bonus numeric)
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
 if p_payment is null or p_payment<=0 or p_payment>100000000 or length(btrim(coalesce(p_reason,'')))<3
 then raise exception 'Valid amount and reason required';end if;
 if p_bonus is null or p_bonus<0 or p_bonus>1000 then raise exception 'Bonus percent required for this correction';end if;
 if not exists(select 1 from public.players p where p.id=p_player and p.workspace_id=old_load.workspace_id)
 or not exists(select 1 from public.games g where g.id=p_game and g.workspace_id=old_load.workspace_id)
 or not exists(select 1 from public.providers p where p.id=p_provider and p.workspace_id=old_load.workspace_id)
 then raise exception 'Invalid player/backend/provider';end if;
 if actor_role in('owner','manager') or now()<=old_load.created_at+interval '15 minutes' then
  perform private.apply_load_change(p_load,p_player,p_game,p_provider,p_payment,p_note,p_reason,p_bonus);
  return 'applied';
 end if;
 insert into public.load_correction_requests(workspace_id,load_id,requested_by,requested_player_id,requested_game_id,requested_provider_id,requested_payment,requested_note,reason,requested_bonus_percent)
 values(old_load.workspace_id,p_load,auth.uid(),p_player,p_game,p_provider,p_payment,p_note,p_reason,p_bonus);
 return 'pending_approval';
end $function$


revoke all on function private.apply_load_change(uuid,uuid,uuid,uuid,numeric,text,text,numeric) from public,anon,authenticated;
revoke all on function public.record_load(uuid,uuid,uuid,numeric,text,numeric) from public,anon;
revoke all on function public.submit_load_correction(uuid,uuid,uuid,uuid,numeric,text,text,numeric) from public,anon;
grant execute on function public.record_load(uuid,uuid,uuid,numeric,text,numeric),
 public.submit_load_correction(uuid,uuid,uuid,uuid,numeric,text,text,numeric),
 public.review_load_correction(uuid,boolean,text) to authenticated;
drop function if exists public.record_load(uuid,uuid,uuid,numeric,text);
drop function if exists public.submit_load_correction(uuid,uuid,uuid,uuid,numeric,text,text);
drop function if exists private.apply_load_change(uuid,uuid,uuid,uuid,numeric,text,text);
drop function if exists public.update_player_bonus(uuid,numeric);
alter table public.players drop column if exists bonus_percent;
