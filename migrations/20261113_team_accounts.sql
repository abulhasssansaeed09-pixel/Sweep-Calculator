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
 unique(login_id)
);
create index if not exists team_accounts_workspace_idx on public.team_accounts(workspace_id);
alter table public.team_accounts enable row level security;
revoke all on public.team_accounts from anon, authenticated;
grant select on public.team_accounts to authenticated;
drop policy if exists team_accounts_owner_read on public.team_accounts;
create policy team_accounts_owner_read on public.team_accounts for select to authenticated
using (exists(select 1 from public.memberships m where m.workspace_id=team_accounts.workspace_id and m.user_id=auth.uid() and m.role='owner'));
-- Existing RLS policies on business tables must ALSO check active team_accounts
-- (or equivalent central membership guard) before deactivation is considered complete.
-- Edge Function with service role is sole writer; never expose service role in browser.
