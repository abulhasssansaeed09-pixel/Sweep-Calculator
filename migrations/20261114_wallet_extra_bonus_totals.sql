-- Player Wallet: total extra bonus points across all historical Load transactions.
-- No initial/default player bonus is introduced or persisted.
-- Bonus is calculated from points actually loaded minus the payment's base points.
-- A server-side aggregate prevents dashboard caching/pagination from dropping historical loads.
create or replace function public.workspace_player_wallet_totals(p_workspace uuid)
returns table (
  player_id uuid,
  extra_bonus_points numeric
)
language sql
stable
security definer
set search_path = ''
as $fn$
  select p.id as player_id,
         coalesce(sum(greatest(l.points - l.payment, 0)), 0)::numeric as extra_bonus_points
  from public.players p
  left join public.loads l
    on l.workspace_id = p.workspace_id and l.player_id = p.id
  where p.workspace_id = p_workspace
    and public.team_access_active(p_workspace)
    and public.is_workspace_member(p_workspace)
  group by p.id
$fn$;
revoke all on function public.workspace_player_wallet_totals(uuid) from public, anon;
grant execute on function public.workspace_player_wallet_totals(uuid) to authenticated;
