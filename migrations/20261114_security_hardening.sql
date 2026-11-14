-- Required security hardening after 20261114_sweep_full_workflow_completion.sql.
-- This prevents active workers from bypassing role checks via direct PostgREST table/view writes.
begin;
do $$
declare t text;
begin
 foreach t in array array['memberships','players','games','providers','loads','cashouts','cashout_audit','cashout_notifications','closings','reloads','expenses','team_accounts']
 loop
  execute format('drop policy if exists team_active_guard on public.%I',t);
  execute format('create policy team_active_guard on public.%I as restrictive for all to authenticated using (public.team_access_active(workspace_id)) with check (public.team_access_active(workspace_id))',t);
 end loop;
end $$;
revoke insert,update,delete on public.memberships from public,anon,authenticated;
revoke insert,update,delete on public.cashouts from public,anon,authenticated;
revoke insert,update,delete on public.cashout_audit from public,anon,authenticated;
revoke insert,update,delete on public.cashout_notifications from public,anon,authenticated;
revoke insert,update,delete on public.closings from public,anon,authenticated;
drop policy if exists closings_insert on public.closings;
revoke insert,update,delete on public.load_correction_requests from public,anon,authenticated;
revoke insert,update,delete on public.load_correction_audit from public,anon,authenticated;
revoke insert,update,delete on public.closing_audit from public,anon,authenticated;
revoke insert,update,delete on public.payment_reconciliations from public,anon,authenticated;
revoke insert,update,delete on public.platform_cashout_rules from public,anon,authenticated;
revoke update,delete on public.players from public,anon,authenticated;
revoke update,delete on public.games from public,anon,authenticated;
revoke update,delete on public.providers from public,anon,authenticated;
revoke update,delete on public.reloads from public,anon,authenticated;
revoke update,delete on public.expenses from public,anon,authenticated;
revoke insert,delete on public.workspaces from public,anon,authenticated;
revoke all on function public.finalize_backend_closing(uuid,numeric) from public,anon,authenticated;
create or replace view public.cashouts_visible as
select c.id,c.workspace_id,c.player_id,c.game_id,c.provider_id,c.points,c.gross_amount,c.net_paid,c.note,
c.created_by,c.created_at,c.review_status,c.review_reason,c.reviewed_by,c.reviewed_at,c.approval_reason,
c.fee_rate,c.fee_fixed,c.fee_bearer
from public.cashouts c
where auth.uid() is not null and public.team_access_active(c.workspace_id) and exists(
 select 1 from public.memberships m where m.user_id=auth.uid() and m.workspace_id=c.workspace_id
);
revoke insert,update,delete on public.cashouts_visible from public,anon,authenticated;
grant select on public.cashouts_visible to authenticated;
commit;
