-- Team identity and access. Apply only after security review and backup.
create table if not exists public.team_accounts (
 user_id uuid primary key references auth.users(id) on delete cascade,
 workspace_id uuid not null references public.workspaces(id),
 login_id text not null,
 role text not null check(role in ('manager','worker')),
 active boolean not null default true,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 session_valid_after timestamptz not null default '-infinity',
 unique(login_id)
);
alter table public.team_accounts add column if not exists session_valid_after timestamptz not null default '-infinity';
create index if not exists team_accounts_workspace_idx on public.team_accounts(workspace_id);
alter table public.team_accounts enable row level security;
revoke all on public.team_accounts from anon, authenticated;
grant select on public.team_accounts to authenticated;
drop policy if exists team_accounts_owner_read on public.team_accounts;
create policy team_accounts_owner_read on public.team_accounts for select to authenticated
using (exists(select 1 from public.memberships m where m.workspace_id=team_accounts.workspace_id and m.user_id=auth.uid() and m.role='owner'));

-- SECURITY: Restrictive policies are AND-ed with all existing permissive RLS policies.
-- A definer function avoids recursive policies between memberships and team_accounts.
create or replace function public.team_access_active(p_workspace uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
 select auth.uid() is not null
 and exists (
   select 1 from public.memberships m
   where m.user_id=auth.uid() and m.workspace_id=p_workspace
   and (m.role='owner' or exists(
     select 1 from public.team_accounts t
     where t.user_id=m.user_id and t.workspace_id=m.workspace_id
       and t.role=m.role and t.active=true
       and exists(select 1 from auth.sessions sess
         where sess.id=(auth.jwt()->>'session_id')::uuid
           and sess.user_id=m.user_id and sess.created_at>t.session_valid_after)
   ) or not exists (
     select 1 from public.team_accounts t2 where t2.user_id=m.user_id
   ))
 );
$$;
revoke all on function public.team_access_active(uuid) from public, anon;
grant execute on function public.team_access_active(uuid) to authenticated;

-- Legacy members without a team_accounts row remain active during migration.\n-- Deactivation is available only for newly managed team accounts.\n-- Existing members must be enrolled before owner can manage their status.\n-- These tables all carry workspace_id. Apply the guard to SELECT and mutations.
-- RLS on a workspace row does not replace the original per-role policies.
do $$
declare tab text;
begin
 foreach tab in array array['memberships','players','games','providers','loads',
  'reloads','closings','expenses','cashouts','cashout_rules',
  'cashout_notifications','team_accounts'] loop
   if to_regclass('public.'||tab) is not null then
     execute format('drop policy if exists team_active_guard on public.%I',tab);
     execute format('create policy team_active_guard on public.%I as restrictive for all to authenticated using (public.team_access_active(workspace_id)) with check (public.team_access_active(workspace_id))',tab);
   end if;
 end loop;
end $$;
-- New tables added later must receive this guard too.
