-- One provider row per company/payment method, preserving all existing IDs and fee snapshots.
create or replace function private.payment_method_key(p_method text) returns text
language sql immutable strict set search_path='' as $$
 select case regexp_replace(lower(btrim(p_method)),'[[:space:]_-]+','','g')
  when 'cashapp' then 'cash app'
  when 'applepay' then 'apple pay'
  when 'googlepay' then 'google pay'
  when 'paypal' then 'paypal'
  when 'chime' then 'chime'
  when 'zelle' then 'zelle'
  when 'crypto' then 'crypto payment'
  when 'cryptopayment' then 'crypto payment'
  when 'card' then 'card payment'
  when 'cardpayment' then 'card payment'
  else regexp_replace(lower(btrim(p_method)),'[[:space:]]+',' ','g')
 end
$$;
create unique index providers_company_method_unique on public.providers (workspace_id, lower(btrim(company)), private.payment_method_key(method));

create or replace function public.save_provider_methods(p_workspace uuid,p_company text,p_methods text[],p_direction text,p_rate numeric,p_fixed numeric)
returns integer language plpgsql security definer set search_path='' as $$
declare method_name text; method_key text; company_name text; existing_id uuid; existing_receive boolean; changed_count integer:=0; actor_role text; seen text[]:='{}';
begin
 select m.role into actor_role from public.memberships m where m.workspace_id=p_workspace and m.user_id=auth.uid();
 if auth.uid() is null or actor_role is null or not public.team_access_active(p_workspace) or actor_role not in ('owner','manager') then raise exception 'Manager/Owner access required';end if;
 if p_direction is null or p_direction not in ('receive','cashout') then raise exception 'Invalid payment direction';end if;
 if p_direction='cashout' and actor_role<>'owner' then raise exception 'Owner access required';end if;
 company_name:=btrim(coalesce(p_company,''));
 if length(company_name) not between 1 and 100 or p_methods is null or cardinality(p_methods) not between 1 and 50 then raise exception 'Enter a company and select at least one payment method (maximum 50)';end if;
 if p_rate is null or p_rate<0 or p_rate>100 or round(p_rate,3)<>p_rate or p_fixed is null or p_fixed<0 or p_fixed>100000000 or round(p_fixed,2)<>p_fixed then raise exception 'Enter valid percentage and fixed fee';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_workspace::text||':'||lower(company_name),0));
 select p.company into company_name from public.providers p where p.workspace_id=p_workspace and lower(btrim(p.company))=lower(btrim(p_company)) order by p.created_at,p.id limit 1;
 company_name:=coalesce(company_name,btrim(p_company));
 foreach method_name in array p_methods loop
  method_name:=btrim(coalesce(method_name,''));
  if length(method_name) not between 1 and 80 then raise exception 'Payment method names must be 1–80 characters';end if;
  method_key:=private.payment_method_key(method_name);
  if method_key=any(seen) then continue;end if;
  seen:=array_append(seen,method_key);
  select p.id,p.receive_enabled into existing_id,existing_receive from public.providers p where p.workspace_id=p_workspace and lower(btrim(p.company))=lower(btrim(company_name)) and private.payment_method_key(p.method)=method_key for update;
  if existing_id is not null then
   if p_direction='cashout' then
    update public.providers set cashout_rate=p_rate,cashout_fixed_fee=p_fixed where id=existing_id;
   else
    if not existing_receive and actor_role<>'owner' then raise exception 'Owner must enable receiving payments for an existing cash-out-only method';end if;
    update public.providers set rate=p_rate,fixed_fee=p_fixed,receive_enabled=true where id=existing_id;
   end if;
  else
   method_name:=case method_key when 'cash app' then 'Cash App' when 'apple pay' then 'Apple Pay' when 'google pay' then 'Google Pay' when 'paypal' then 'PayPal' when 'zelle' then 'Zelle' when 'chime' then 'Chime' when 'crypto payment' then 'Crypto Payment' when 'card payment' then 'Card Payment' else method_name end;
   insert into public.providers(workspace_id,company,method,rate,fixed_fee,receive_enabled,cashout_rate,cashout_fixed_fee)
   values(p_workspace,company_name,method_name,case when p_direction='receive' then p_rate else 0 end,case when p_direction='receive' then p_fixed else 0 end,p_direction='receive',case when p_direction='cashout' then p_rate else null end,case when p_direction='cashout' then p_fixed else 0 end);
  end if;
  changed_count:=changed_count+1;
 end loop;
 return changed_count;
end $$;
revoke all on function public.save_provider_methods(uuid,text,text[],text,numeric,numeric) from public,anon;
grant execute on function public.save_provider_methods(uuid,text,text[],text,numeric,numeric) to authenticated;
