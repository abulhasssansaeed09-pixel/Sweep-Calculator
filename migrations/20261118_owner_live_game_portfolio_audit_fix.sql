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
 insert into public.closing_audit(workspace_id,closing_id,actor_id,action,reason,old_record,new_record)
 values(w,row_out.id,auth.uid(),'opening_balance','Owner recorded actual opening balance','{}'::jsonb,to_jsonb(row_out));
 return row_out.id;
end $$;
revoke all on function public.record_game_opening_balance(uuid,numeric) from public,anon;
grant execute on function public.record_game_opening_balance(uuid,numeric) to authenticated;
