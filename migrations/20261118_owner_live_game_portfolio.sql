-- Owner-only game analytics: current business day and complete recorded history.
create or replace function public.workspace_game_portfolio(p_workspace uuid)
returns table(game_id uuid,game_name text,day_start timestamptz,day_end timestamptz,
 day_deposits numeric,day_points_loaded numeric,day_gross_cashouts numeric,day_points_redeemed numeric,day_winning_players bigint,day_deposit_count bigint,day_win_ratio numeric,
 total_deposits numeric,total_points_loaded numeric,total_bonus_points numeric,total_gross_cashouts numeric,total_net_cashouts numeric,total_points_redeemed numeric,total_deposit_count bigint,total_cashout_count bigint,total_players bigint,total_depositors bigint,regular_players bigint,game_regular_players bigint,total_win_ratio numeric)
language plpgsql stable security definer set search_path='' as $$
declare tz text; cutoff time; local_clock timestamp; local_start timestamp; from_at timestamptz; to_at timestamptz;
begin
 if auth.uid() is null or not public.team_access_active(p_workspace) or not exists(select 1 from public.memberships m where m.workspace_id=p_workspace and m.user_id=auth.uid() and m.role='owner') then raise exception 'Owner access required';end if;
 select coalesce(w.closing_timezone,'UTC'),coalesce(w.closing_time,'11:00'::time) into tz,cutoff from public.workspaces w where w.id=p_workspace;
 local_clock:=now() at time zone tz;
 local_start:=local_clock::date+cutoff;
 if local_start>local_clock then local_start:=local_start-interval '1 day';end if;
 from_at:=local_start at time zone tz;
 to_at:=(local_start+interval '1 day') at time zone tz;
 return query
 with l as (
 select x.game_id,x.player_id,count(*) filter(where x.payment>0) paid_loads,
   coalesce(sum(x.payment),0) deposits,coalesce(sum(x.points),0) points,coalesce(sum(greatest(x.points-x.payment,0)),0) bonus,
   coalesce(sum(x.payment) filter(where x.created_at>=from_at and x.created_at<to_at),0) today_deposits,
   coalesce(sum(x.points) filter(where x.created_at>=from_at and x.created_at<to_at),0) today_points,
   count(*) filter(where x.payment>0 and x.created_at>=from_at and x.created_at<to_at) today_count
 from public.loads x where x.workspace_id=p_workspace group by x.game_id,x.player_id
 ), regular as (
 select l.player_id,sum(l.paid_loads) total_paid_loads from l group by l.player_id
 ), c as (
 select x.game_id,x.player_id,count(*) cashouts,coalesce(sum(x.gross_amount),0) gross,coalesce(sum(x.net_paid),0) net,coalesce(sum(x.points),0) points,
 coalesce(sum(x.gross_amount) filter(where x.created_at>=from_at and x.created_at<to_at),0) today_gross,
 coalesce(sum(x.points) filter(where x.created_at>=from_at and x.created_at<to_at),0) today_points
 from public.cashouts x where x.workspace_id=p_workspace group by x.game_id,x.player_id
 ), by_player as (
 select coalesce(l.game_id,c.game_id) gid,coalesce(l.player_id,c.player_id) pid,
 coalesce(l.paid_loads,0) paid_loads,coalesce(l.deposits,0) deposits,coalesce(l.points,0) loaded,coalesce(l.bonus,0) bonus,
 coalesce(l.today_deposits,0) day_deposits,coalesce(l.today_points,0) day_loaded,coalesce(l.today_count,0) day_count,
 coalesce(c.cashouts,0) cashouts,coalesce(c.gross,0) gross,coalesce(c.net,0) net,coalesce(c.points,0) redeemed,
 coalesce(c.today_gross,0) today_gross,coalesce(c.today_points,0) today_redeemed
 from l full join c on l.game_id=c.game_id and l.player_id=c.player_id
 ), stats as (
 select p.gid,sum(p.day_deposits) dd,sum(p.day_loaded) dl,sum(p.today_gross) dg,sum(p.today_redeemed) dr,
 count(*) filter(where p.today_gross>0) dw,sum(p.day_count)::bigint dc,
 sum(p.deposits) td,sum(p.loaded) tl,sum(p.bonus) tb,sum(p.gross) tg,sum(p.net) tn,sum(p.redeemed) tr,
 sum(p.paid_loads)::bigint tdc,sum(p.cashouts)::bigint tcc,count(*) tp,count(*) filter(where p.paid_loads>0) tdp,
 count(*) filter(where coalesce(r.total_paid_loads,0)>5) rp,count(*) filter(where p.paid_loads>5) grp
 from by_player p left join regular r on r.player_id=p.pid group by p.gid
 )
 select g.id,g.name,from_at,to_at,coalesce(s.dd,0),coalesce(s.dl,0),coalesce(s.dg,0),coalesce(s.dr,0),coalesce(s.dw,0::bigint),coalesce(s.dc,0::bigint),
 case when s.dd>0 then round(s.dg/s.dd*100,2) else null end,
 coalesce(s.td,0),coalesce(s.tl,0),coalesce(s.tb,0),coalesce(s.tg,0),coalesce(s.tn,0),coalesce(s.tr,0),
 coalesce(s.tdc,0::bigint),coalesce(s.tcc,0::bigint),coalesce(s.tp,0::bigint),coalesce(s.tdp,0::bigint),coalesce(s.rp,0::bigint),coalesce(s.grp,0::bigint),
 case when s.td>0 then round(s.tg/s.td*100,2) else null end
 from public.games g left join stats s on s.gid=g.id where g.workspace_id=p_workspace order by g.name,g.id;
end $$;
revoke all on function public.workspace_game_portfolio(uuid) from public,anon;
grant execute on function public.workspace_game_portfolio(uuid) to authenticated;

-- Owner may initialize the actual balance once; normal closing authority remains with Manager.
create or replace function public.record_game_opening_balance(p_game uuid,p_balance numeric)
returns uuid language plpgsql security definer set search_path='' as $$
declare w uuid; measured_at timestamptz; row_out public.closings%rowtype;
begin
 select g.workspace_id into w from public.games g where g.id=p_game;
 if auth.uid() is null or w is null or not public.team_access_active(w) or not exists(select 1 from public.memberships m where m.workspace_id=w and m.user_id=auth.uid() and m.role='owner') then raise exception 'Owner access required';end if;
 if p_balance is null or p_balance<0 or p_balance>100000000000 or round(p_balance,2)<>p_balance then raise exception 'Enter a valid actual points balance (up to 2 decimals)';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_game::text,0));
 if exists(select 1 from public.closings c where c.workspace_id=w and c.game_id=p_game) then raise exception 'Opening balance already recorded; use Backend Closing for later entries';end if;
 measured_at:=now();
 insert into public.closings(workspace_id,game_id,balance,created_by,period_start,period_end,manager_note,review_status)
 values(w,p_game,p_balance,auth.uid(),measured_at,measured_at,'Owner recorded actual opening balance','approved') returning * into row_out;
 insert into public.closing_audit(workspace_id,closing_id,actor_id,action,reason,new_record)
 values(w,row_out.id,auth.uid(),'opening_balance','Owner recorded actual opening balance',to_jsonb(row_out));
 return row_out.id;
end $$;
revoke all on function public.record_game_opening_balance(uuid,numeric) from public,anon;
grant execute on function public.record_game_opening_balance(uuid,numeric) to authenticated;
