-- Secure full-history aggregate for Owner/Manager Overview.
-- Total Extra Bonus Points = points credited - payment received.
-- Extra Bonus Cost = extra bonus points times the backend purchase rate snapshotted on each load.
-- Per-player default bonus settings do not exist.
create or replace function public.workspace_extra_bonus_overview(p_workspace uuid)
returns table(total_extra_bonus_points numeric,total_extra_bonus_cost numeric)
language plpgsql stable security definer set search_path='' as $$
begin
 if p_workspace is null or not public.team_access_active(p_workspace)
 or not public.is_workspace_manager(p_workspace)
 then raise exception 'Owner or Manager access required'; end if;
 return query select
   round(coalesce(sum(greatest(l.points-l.payment,0)),0),2),
   round(coalesce(sum(greatest(l.points-l.payment,0)*coalesce(l.purchase_rate,0)/100),0),2)
 from public.loads l where l.workspace_id=p_workspace;
end $$;
revoke all on function public.workspace_extra_bonus_overview(uuid) from public,anon;
grant execute on function public.workspace_extra_bonus_overview(uuid) to authenticated;