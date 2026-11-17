alter table public.games add column if not exists logo_data text;
alter table public.games add constraint games_logo_data_valid check (logo_data is null or (length(logo_data)<=100000 and logo_data ~ '^data:image/(webp|png);base64,[A-Za-z0-9+/]+={0,2}$'));
create table public.provider_company_logos (
 workspace_id uuid not null references public.workspaces(id) on delete cascade,
 company_key text not null check (company_key = lower(btrim(company_key)) and length(company_key) between 1 and 100),
 logo_data text not null check (length(logo_data)<=100000 and logo_data ~ '^data:image/(webp|png);base64,[A-Za-z0-9+/]+={0,2}$'),
 primary key(workspace_id, company_key)
);
alter table public.provider_company_logos enable row level security;
revoke all on public.provider_company_logos from anon, authenticated;
grant select,insert,update on public.provider_company_logos to authenticated;
create policy company_logo_read on public.provider_company_logos for select to authenticated using (public.is_workspace_member(workspace_id) and public.team_access_active(workspace_id));
create policy company_logo_insert on public.provider_company_logos for insert to authenticated with check (public.is_workspace_manager(workspace_id) and public.team_access_active(workspace_id));
create policy company_logo_update on public.provider_company_logos for update to authenticated using (public.is_workspace_manager(workspace_id) and public.team_access_active(workspace_id)) with check (public.is_workspace_manager(workspace_id) and public.team_access_active(workspace_id));
create function public.save_provider_methods_with_logo(p_workspace uuid,p_company text,p_methods text[],p_direction text,p_rate numeric,p_fixed numeric,p_logo text default null)
returns integer language plpgsql security invoker set search_path='' as $$
declare saved integer;
begin
 saved:=public.save_provider_methods(p_workspace,p_company,p_methods,p_direction,p_rate,p_fixed);
 if p_logo is not null then
 insert into public.provider_company_logos(workspace_id,company_key,logo_data)
 values(p_workspace,lower(btrim(p_company)),p_logo)
 on conflict(workspace_id,company_key) do update set logo_data=excluded.logo_data;
 end if;
 return saved;
end; $$;
revoke all on function public.save_provider_methods_with_logo(uuid,text,text[],text,numeric,numeric,text) from public,anon;
grant execute on function public.save_provider_methods_with_logo(uuid,text,text[],text,numeric,numeric,text) to authenticated;