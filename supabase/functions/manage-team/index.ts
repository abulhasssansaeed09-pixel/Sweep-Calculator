import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.95.3';
const cors={'access-control-allow-origin':'*','access-control-allow-headers':'authorization, x-client-info, apikey, content-type','access-control-allow-methods':'POST, OPTIONS'};
const json=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'content-type':'application/json','cache-control':'no-store'}});
const synthetic=(login:string)=>'team-'+Array.from(new TextEncoder().encode(login)).map(x=>x.toString(16).padStart(2,'0')).join('')+'@login.invalid';
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
 if(req.method!=='POST')return json({error:'Method not allowed'},405);
 const url=Deno.env.get('SUPABASE_URL'),anon=Deno.env.get('SUPABASE_ANON_KEY'),secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
 if(!url||!anon||!secret)return json({error:'Server not configured'},503);
 const token=req.headers.get('authorization')?.replace(/^Bearer /i,'');
 if(!token)return json({error:'Unauthorized'},401);
 const auth=createClient(url,anon,{global:{headers:{Authorization:'Bearer '+token}}});
 const {data:{user},error:authError}=await auth.auth.getUser();
 if(authError||!user)return json({error:'Unauthorized'},401);
 const admin=createClient(url,secret,{auth:{autoRefreshToken:false,persistSession:false}});
 let input:any;try{input=await req.json()}catch{return json({error:'Invalid JSON'},400)}
 const workspace_id=String(input.workspace_id||'');
 if(!/^[0-9a-f-]{36}$/i.test(workspace_id))return json({error:'Invalid workspace'},400);
 const {data:membership,error:membershipError}=await admin.from('memberships').select('role').eq('workspace_id',workspace_id).eq('user_id',user.id).maybeSingle();
 if(membershipError||membership?.role!=='owner')return json({error:'Forbidden'},403);
 const action=String(input.action||'');
 if(action==='create'){
  const login=String(input.login_id||'').trim().toLowerCase(),role=String(input.role||''),password=String(input.password||'');
  if(!/^[a-z0-9][a-z0-9._@+-]{2,99}$/.test(login)||!['manager','worker'].includes(role)||password.length<12||password.length>128)return json({error:'Invalid login, role or password (minimum 12 characters)'},400);
  const {data:duplicate}=await admin.from('team_accounts').select('user_id').eq('login_id',login).maybeSingle();
  if(duplicate)return json({error:'Login identifier already used'},409);
  const email=synthetic(login);
  const {data:created,error:createError}=await admin.auth.admin.createUser({email,password,email_confirm:true,app_metadata:{team_account:true}});
  if(createError||!created.user)return json({error:'Account could not be created'},400);
  const id=created.user.id;
  const {error:profileError}=await admin.from('team_accounts').insert({user_id:id,workspace_id,login_id:login,role,created_by:user.id});
  const {error:memberError}=profileError?{error:profileError}:await admin.from('memberships').insert({user_id:id,workspace_id,role});
  if(memberError){await admin.from('team_accounts').delete().eq('user_id',id);await admin.auth.admin.deleteUser(id);return json({error:'Account creation failed; rolled back'},500)}
  return json({user_id:id,login_id:login,role,active:true},201);
 }
 if(['reset_password','set_active'].includes(action)){
  const target=String(input.user_id||'');
  const {data:account}=await admin.from('team_accounts').select('user_id,active').eq('workspace_id',workspace_id).eq('user_id',target).maybeSingle();
  if(!account)return json({error:'Team account not found'},404);
  if(action==='reset_password'){
   const password=String(input.password||'');
   if(password.length<12||password.length>128)return json({error:'Password must be 12–128 characters'},400);
   const {error}=await admin.auth.admin.updateUserById(target,{password});
   return error?json({error:'Password reset failed'},500):json({ok:true});
  }
  if(typeof input.active!=='boolean')return json({error:'Invalid status'},400);
  const {error}=await admin.from('team_accounts').update({active:input.active,updated_at:new Date().toISOString()}).eq('user_id',target).eq('workspace_id',workspace_id);
  if(error)return json({error:'Status update failed'},500);
  if(!input.active){const {error:banError}=await admin.auth.admin.updateUserById(target,{ban_duration:'876000h'});if(banError)return json({error:'Account marked inactive but auth ban failed; retry'},500)}
  else {const {error:unbanError}=await admin.auth.admin.updateUserById(target,{ban_duration:'none'});if(unbanError)return json({error:'Status marked active but auth unban failed; retry'},500)}
  return json({ok:true,active:input.active});
 }
 return json({error:'Unknown action'},400);
});
