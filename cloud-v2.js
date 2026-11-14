import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.95.3';
const sb=createClient('https://gkrlbwxetdmoqrxdbeok.supabase.co','sb_publishable_eVFpo2WzzfXFJhFJM8YAlQ_SVs_QUZJ');
const root=document.getElementById('cloud'), esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;','\'':'&#39;'}[c]));
const money=n=>'$'+Number(n||0).toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2}),fmt=n=>Number(n||0).toLocaleString('en-US',{maximumFractionDigits:2}),date=s=>s?new Date(s).toLocaleString():'—';
const sum=(a,fn)=>a.reduce((v,x)=>v+Number(fn(x)||0),0),fld=(n,l,type='text',extra='')=>'<label class="field">'+l+'<input name="'+n+'" type="'+type+'" '+extra+' required></label>';
const selectedOptions=(a,label,fn,id)=>'<option value="">'+label+'</option>'+a.map(x=>'<option value="'+esc(x.id)+'" '+(x.id===id?'selected':'')+'>'+esc(fn(x))+'</option>').join('');
const options=(a,label,fn)=>'<option value="">'+label+'</option>'+a.map(x=>'<option value="'+esc(x.id)+'">'+esc(fn(x))+'</option>').join('');
const panel=(t,html)=>'<section class="card panel"><h2>'+t+'</h2>'+html+'</section>';
const tbl=(head,rows)=>'<div class="tablewrap"><table><thead><tr>'+head.map(h=>'<th>'+h+'</th>').join('')+'</tr></thead><tbody>'+(rows.length?rows.map(row=>'<tr>'+row.map(c=>'<td>'+c+'</td>').join('')+'</tr>').join(''):'<tr><td colspan="'+head.length+'" class="empty">No records yet</td></tr>')+'</tbody></table></div>';
let user=null,workspace=null,role=null,tab='overview',channel=null,busy=false,authCooldown=0;
let reconciliations=[],loadCorrections=[],loadAudit=[],closingAudit=[],cashoutAudit=[],walletBonusTotals=new Map();let reportSummaries={day:[],week:[],month:[]},loaderPerformance=[],backendTicker=[];let teamAccounts=[];let players=[],games=[],providers=[],loads=[],reloads=[],closings=[],expenses=[],members=[],cashouts=[],cashoutNotifications=[],cashoutRules=[];
const manager=()=>['owner','manager'].includes(role);
const playerName=id=>players.find(x=>x.id===id)?.name||'Unknown';
const gameName=id=>games.find(x=>x.id===id)?.name||'Unknown';
const workerName=id=>loaderPerformance.find(x=>x.worker_id===id)?.login_label||teamAccounts.find(x=>x.user_id===id)?.login_id||(id||'').slice(0,8);
function message(s){const el=document.getElementById('message');if(el)el.textContent=s;else alert(s)}
const teamEmail=async login=>{const hash=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(login.trim().toLowerCase()));return 'team-'+Array.from(new Uint8Array(hash)).map(x=>x.toString(16).padStart(2,'0')).join('')+'@login.invalid'};
function authPage(){root.innerHTML=panel('Sign in or create owner account','<p class="muted">Owner: email and password. Team: username or email-style ID and password. Use test data during beta.</p><form id="auth" class="stack">'+fld('email','Email or username','text')+fld('password','Password','password','minlength="8"')+'<div class="actions"><button name="action" value="signin" class="primary">Sign in</button><button name="action" value="signup" class="ghost">Sign up</button></div><p id="message" class="muted"></p></form>')}
function setupPage(){root.innerHTML=panel('Create your private workspace','<p class="muted">Business owners only. Manager and Loader accounts are created manually by the Owner.</p><form id="workspace" class="stack">'+fld('name','Business name')+'<button class="primary">Create workspace</button></form><button data-action="signout" class="ghost">Sign out</button><p id="message"></p>')}
async function boot(){const {data:{user:u},error}=await sb.auth.getUser();if(error||!u){user=null;authPage();return}user=u;const r=await sb.from('memberships').select('workspace_id,user_id,role,workspaces(id,name,closing_time,closing_timezone)').eq('user_id',u.id).limit(1).maybeSingle();if(r.error){root.textContent=r.error.message;return}if(!r.data){setupPage();return}if(r.data.user_id!==u.id){await sb.auth.signOut();user=null;workspace=null;role=null;authPage();message('Account role mismatch. Please contact the Owner.');return}role=r.data.role;workspace=r.data.workspaces;await refresh();subscribe()}

async function fetchWorkspaceRows(name,order){
 const table=name==='cashouts'?'cashouts_visible':name;
 const full=['players','loads','cashouts'].includes(name);
 if(!full)return sb.from(table).select('*').eq('workspace_id',workspace.id).order(order,{ascending:false}).limit(1000);
 let records=[],start=0;
 while(true){
  const r=await sb.from(table).select('*').eq('workspace_id',workspace.id).order(order,{ascending:false}).range(start,start+999);
  if(r.error)return r;
  const part=r.data||[];records.push(...part);
  if(part.length<1000)break;
  start+=1000;
 }
 return {data:records,error:null};
}

async function refresh(){if(!workspace)return;const specs=[['cashout_audit','created_at'],['closing_audit','created_at'],['load_correction_requests','created_at'],['load_correction_audit','created_at'],['payment_reconciliations','created_at'],['team_accounts','created_at'],['platform_cashout_rules','workspace_id'],['cashout_notifications','created_at'],['cashouts','created_at'],['players','created_at'],['games','created_at'],['providers','created_at'],['loads','created_at'],['reloads','created_at'],['closings','created_at'],['expenses','created_at'],['memberships','created_at']];
const selected=specs.filter(([name])=>(name!=='platform_cashout_rules'||role==='owner')&&(name!=='team_accounts'||role==='owner')&&(manager()||!['reloads','closings','expenses','memberships','cashout_notifications','platform_cashout_rules','payment_reconciliations','load_correction_audit','closing_audit','cashout_audit'].includes(name)));
const responses=await Promise.all(selected.map(([name,order])=>fetchWorkspaceRows(name,order)));
const failure=responses.find(x=>x.error);if(failure){root.innerHTML=panel('Database error',esc(failure.error.message));return}
const map=Object.fromEntries(selected.map(([name],i)=>[name,responses[i].data||[]]));
cashoutAudit=map.cashout_audit||[];closingAudit=map.closing_audit||[];loadCorrections=map.load_correction_requests||[];loadAudit=map.load_correction_audit||[];reconciliations=map.payment_reconciliations||[];teamAccounts=map.team_accounts||[];players=map.players||[];games=map.games||[];providers=map.providers||[];loads=map.loads||[];reloads=map.reloads||[];closings=map.closings||[];expenses=map.expenses||[];members=map.memberships||[];cashouts=map.cashouts||[];cashoutNotifications=map.cashout_notifications||[];cashoutRules=map.platform_cashout_rules||[];
const walletTotalsResponse=await sb.rpc('workspace_player_wallet_totals',{p_workspace:workspace.id});
if(walletTotalsResponse.error){root.innerHTML=panel('Wallet summary error',esc(walletTotalsResponse.error.message));return}
walletBonusTotals=new Map((walletTotalsResponse.data||[]).map(x=>[x.player_id,Number(x.extra_bonus_points||0)]));
if(manager()){const calls=await Promise.all([sb.rpc('workspace_report_summary',{p_workspace:workspace.id,p_bucket:'day'}),sb.rpc('workspace_report_summary',{p_workspace:workspace.id,p_bucket:'week'}),sb.rpc('workspace_report_summary',{p_workspace:workspace.id,p_bucket:'month'}),sb.rpc('workspace_loader_performance',{p_workspace:workspace.id}),sb.rpc('backend_live_ticker',{p_workspace:workspace.id})]);const failure=calls.find(x=>x.error);if(failure){root.innerHTML=panel('Reporting error',esc(failure.error.message));return}reportSummaries={day:calls[0].data||[],week:calls[1].data||[],month:calls[2].data||[]};loaderPerformance=calls[3].data||[];backendTicker=calls[4].data||[]}
render()}
const navigation=[['overview','Overview'],['players','Player Wallet'],['load','New Load'],['cashout','Cash Outs'],['backend','Backend Closing'],['payments','Payment Closing'],['reloads','Backend Reloads'],['reports','Reports'],['expenses','Expenses'],['settings','Settings'],['team','Team']];
function render(){if(!manager()&&['backend','payments','reloads','reports','expenses','settings','team'].includes(tab))tab='overview';
const visible=navigation.filter(([id])=>manager()||!['backend','payments','reloads','reports','expenses','settings','team'].includes(id));
const nav='<nav class="cloud-nav">'+visible.map(([id,label])=>'<button type="button" data-tab="'+id+'" class="'+(tab===id?'active':'')+'">'+label+'</button>').join('')+'</nav>';
const pages={overview:overviewPage,players:playersPage,load:loadPage,cashout:cashoutPage,backend:backendPage,payments:paymentsPage,reloads:reloadsPage,reports:reportsPage,expenses:expensesPage,settings:settingsPage,team:teamPage};
root.innerHTML='<div class="row"><div><b>'+esc(workspace.name)+'</b> <span class="pill">'+esc(role)+'</span></div><div class="actions"><button data-action="refresh" class="ghost">Refresh</button><button data-action="signout" class="ghost">Sign out</button></div></div>'+nav+'<div class="cloud-content">'+pages[tab]()+'</div><p class="muted" id="message" style="margin:16px 0">Cloud data · '+(manager()?'Owner/Manager view':'Worker view')+' · Test transactions only</p>'}
function metric(t,v){return '<div class="card"><div class="metric-label">'+t+'</div><div class="metric-value">'+v+'</div></div>'}

function overviewPage(){
 const all=reportSummaries.day||[];
 const gross=manager()?sum(all,x=>x.gross):sum(loads,l=>l.payment);
 const fees=manager()?sum(all,x=>x.provider_fees):0;
 const reloadCost=manager()?sum(all,x=>x.reload_cost):0;
 const estimatedCost=manager()?sum(all,x=>x.estimated_point_cost):0;
 const expenseTotal=manager()?sum(all,x=>x.expense_cost):0;
 const paid=manager()?sum(all,x=>x.cashouts_paid):0;
 const loaded=manager()?sum(all,x=>x.points):sum(loads,x=>x.points);
 const pendingClosings=closings.filter(x=>x.review_status==='review_required'),pendingLoads=loadCorrections.filter(x=>x.status==='pending'),pendingCashouts=cashouts.filter(x=>x.review_status==='review_required'),pendingPayments=reconciliations.filter(x=>['mismatch','stale'].includes(x.review_status));
 return '<div class="grid">'+metric('Players (cached)',players.length)+metric('Total Loads',manager()?fmt(sum(all,x=>x.loads_count)):loads.length)+metric('Customer Payments',money(gross))+metric('Points Loaded',fmt(loaded))+'</div>'+
 (manager()?'<div class="grid" style="margin-top:14px">'+metric('Provider Fees',money(fees))+metric('Estimated Net Points Cost',money(estimatedCost))+metric('Actual Backend Purchases',money(reloadCost))+metric('Expenses',money(expenseTotal))+'</div><div class="grid" style="margin-top:14px">'+metric('Cash Outs Paid',money(paid))+metric('Estimated Operating Margin',money(gross-fees-estimatedCost-expenseTotal-paid))+metric('Cash Flow (not profit)',money(gross-fees-reloadCost-expenseTotal-paid))+'</div><p class="muted">Estimated margin values inventory movement at backend purchase rates; cash flow uses actual reload purchases. Neither is finalized accounting profit.</p>'+
 panel('Manager / Owner Action Queue','<div class="grid">'+metric('Closing Reviews',pendingClosings.length)+metric('Load Corrections Pending',pendingLoads.length)+metric('Cash-Out Reviews',pendingCashouts.length)+metric('Settlement Mismatches',pendingPayments.length)+'</div>'+
 (pendingClosings.length?'<p>Backend Closing: mismatched, late or corrected records need Owner review.</p>':'')+
 (pendingLoads.length?'<p>New Load: workers have corrections waiting for approval.</p>':'')+
 (pendingCashouts.length?'<p>Cash Outs: review cases are waiting for Owner approval.</p>':'')+
 (pendingPayments.length?'<p>Payment Closing: actual settlement differs from recorded totals.</p>':''))+
 panel('Live Backend Points (Estimate)',backendTickerTable()):'')+
 panel('Recent Transactions',loadTable(loads.slice(0,12)));
}
function backendTickerTable(){
 return '<p class="muted">Estimated balance = last recorded actual + reloads + cash-out point credits − loaded points since that closing. Verify against the real backend before finalizing.</p>'+
 tbl(['Backend','Last Actual','Reloads','Loads','Cash-Out Credits','Estimated Now','Last Closing','Alerts'],
 backendTicker.map(x=>[esc(x.game_name),x.starting_balance===null?'Baseline needed':fmt(x.starting_balance),fmt(x.points_reloaded),fmt(x.points_loaded),fmt(x.cashout_credit),
 x.estimated_available===null?'—':fmt(x.estimated_available),date(x.last_closing_at),x.needs_review?'Review required':'—']));
}

function loadTable(rows){return tbl(['Date','Player','Backend','Received','Points','Bonus','Worker'],rows.map(l=>[date(l.created_at),esc(playerName(l.player_id)),esc(gameName(l.game_id)),money(l.payment),fmt(l.points),fmt(Number(l.points)-Number(l.payment)),esc(workerName(l.created_by))]))}

function walletHistoryRows(playerIds){
 const ids=playerIds?new Set(playerIds):null;
 const items=[
  ...loads.filter(x=>!ids||ids.has(x.player_id)).map(l=>({at:l.created_at,id:l.id,pid:l.player_id,kind:'Load',backend:l.game_id,provider:l.provider_id,amount:l.payment,points:l.points,bonus:Number(l.points)-Number(l.payment),note:l.note||'',worker:l.created_by,status:l.correction_reason?'Corrected':'Recorded'})),
  ...cashouts.filter(x=>!ids||ids.has(x.player_id)).map(x=>({at:x.created_at,id:x.id,pid:x.player_id,kind:'Cash Out',backend:x.game_id,provider:x.provider_id,amount:x.net_paid,points:x.points,bonus:null,note:x.note||'',worker:x.created_by,status:x.review_status}))
 ].sort((a,b)=>b.at.localeCompare(a.at));
 return items.map(x=>[date(x.at),esc(playerName(x.pid)),esc(x.kind),esc(gameName(x.backend)),esc(providers.find(p=>p.id===x.provider)?.method||'—'),money(x.amount),fmt(x.points),x.bonus===null?'—':fmt(x.bonus),esc(x.status),esc(x.note),esc(workerName(x.worker))])
}
function walletSummaryRows(collection){
 return collection.map(p=>{
 const ls=loads.filter(l=>l.player_id===p.id),cs=cashouts.filter(x=>x.player_id===p.id);
 const newBadge=Date.now()-new Date(p.created_at).getTime()<48*3600000?' <span class="pill">New</span>':'';
 return [
   esc(p.name)+newBadge,
   '<strong>'+fmt(walletBonusTotals.get(p.id)||0)+' pts</strong>',
   money(sum(ls,l=>l.payment)),
   fmt(sum(ls,l=>l.points)),
   fmt(sum(cs,x=>x.points)),
   ls.length,
   cs.length,
   '<code title="Full player ID: '+esc(p.id)+'">'+esc(p.id.slice(0,8))+'</code>'
 ];
 })}
function playersPage(){
 const walletHeaders=['Player','Extra Bonus (Total)','Payments','Loaded','Redeemed','Loads','Cash Outs','Player ID'];
 const summary=tbl(walletHeaders,walletSummaryRows(players));
 return '<div class="two">'+panel('Create Player','<form id="player" class="stack">'+fld('name','Player name / ID')+'<button class="primary">Save Player</button></form>')+
 panel('Player Wallets','<label class="field">Search player / unique ID<input id="wallet-search" type="search" placeholder="Search by name or full ID"></label><p class="muted">Extra Bonus (Total) = all bonus points added across this player’s Load transactions. The player ID is shortened for display; searching by full ID still works.</p><div id="wallet-results">'+summary+'</div>')+'</div>'+
 panel('Complete Wallet History','<div id="wallet-history">'+tbl(['Date','Player','Type','Backend','Method','Paid/Received','Points','Bonus','Status','Note','Worker'],walletHistoryRows())+'</div>');
}

function correctionEditor(l){
 if(role==='worker'&&l.created_by!==user.id)return '';
 return '<details><summary>Correct load '+esc(l.id.slice(0,8))+'</summary><form id="load-correction" class="stack">'+
 '<input name="load_id" type="hidden" value="'+esc(l.id)+'">'+
 '<label class="field">Player<select name="player_id" required>'+selectedOptions(players,'Choose player',p=>p.name,l.player_id)+'</select></label>'+
 '<label class="field">Backend<select name="game_id" required>'+selectedOptions(games,'Choose backend',g=>g.name,l.game_id)+'</select></label>'+
 '<label class="field">Provider<select name="provider_id" required>'+selectedOptions(providers,'Choose provider',p=>p.company+' / '+p.method,l.provider_id)+'</select></label>'+
 fld('payment','Corrected payment ($)','number','min="0.01" step="0.01" value="'+esc(l.payment)+'"')+
 fld('bonus','Bonus for this load (%)','number','min="0" max="1000" step="0.01" value="'+esc(l.bonus_percent===0&&Number(l.points)!==Number(l.payment)&&Number(l.payment)>0?Math.max(0,Math.round((Number(l.points)/Number(l.payment)-1)*10000)/100):l.bonus_percent)+'"')+
 '<label class="field">Notes<textarea name="note" rows="2">'+esc(l.note||'')+'</textarea></label>'+
 '<label class="field">Reason<input name="reason" type="text" required minlength="3" placeholder="Explain correction"></label>'+
 '<button class="primary">Submit Correction</button></form><p class="muted">Own loads within 15 minutes: instant correction. Later: manager approval. Manager/Owner changes are audited immediately.</p></details>';
}
function loadPage(){
 const show=role==='worker'?loads.filter(l=>l.created_by===user.id):loads;
 const pending=loadCorrections.filter(x=>x.status==='pending');
 const approvals=manager()?panel('Pending Load Corrections · '+pending.length,
  tbl(['Request','Loader','Load','Proposed Payment','Bonus %','Reason','Review'],pending.map(x=>[
   date(x.created_at),esc(workerName(x.requested_by)),esc(x.load_id.slice(0,8)),money(x.requested_payment),fmt(x.requested_bonus_percent)+'%',esc(x.reason),
   '<form id="review-load-correction" class="stack"><input type="hidden" name="request_id" value="'+esc(x.id)+'"><input name="note" placeholder="Review notes" required minlength="3"><div class="actions"><button name="decision" value="approve" class="primary">Approve</button><button name="decision" value="reject" class="ghost">Reject</button></div></form>'])))+
  panel('Correction Audit',tbl(['Date','Load','Actor','Reason'],loadAudit.slice(0,80).map(x=>[date(x.created_at),esc(x.load_id.slice(0,8)),esc(workerName(x.actor_id)),esc(x.reason)]))):'';
 return panel('New Load','<form id="load" class="stack"><label class="field">Player<select name="player_id" required>'+
 options(players,'Choose player',p=>p.name)+'</select></label>'+
 '<label class="field">Backend<select name="game_id" required>'+options(games,'Choose backend',g=>g.name)+'</select></label>'+
 '<label class="field">Payment provider<select name="provider_id" required>'+options(providers,'Choose provider',p=>p.company+' / '+p.method)+'</select></label>'+
 fld('payment','Payment received ($)','number','min="0.01" step="0.01"')+
 fld('bonus','Bonus for THIS load (%)','number','min="0" max="1000" step="0.01" placeholder="Type 0 for no bonus"')+
 '<label class="field">Notes (optional)<textarea name="note" rows="2"></textarea></label>'+
 '<p id="load-preview" class="muted">Enter the payment and a bonus percentage for this transaction. No bonus is saved as a player setting.</p>'+
 '<button class="primary">Record Load</button></form>')+

 panel('Recent Loads',loadTable(show.slice(0,50)))+
 panel('Correct a Load',show.slice(0,20).map(correctionEditor).join('')||'<p class="muted">No eligible loads.</p>')+
 panel('My Correction Requests',tbl(['Date','Load','New Payment','Bonus %','Status','Reason'],loadCorrections.filter(x=>role==='worker'?x.requested_by===user.id:true).slice(0,60).map(x=>[date(x.created_at),esc(x.load_id.slice(0,8)),money(x.requested_payment),fmt(x.requested_bonus_percent)+'%',esc(x.status),esc(x.reason)])))+approvals;
}

function cashoutPage(){
 const form=panel('Record Cash Out','<form id="cashout" class="stack"><label class="field">Player<select name="player_id" required>'+options(players,'Choose player',p=>p.name)+'</select></label><label class="field">Backend<select name="game_id" required>'+options(games,'Choose backend',g=>g.name)+'</select></label><label class="field">Payment method<select name="provider_id" required>'+options(providers,'Choose provider',p=>p.company+' / '+p.method)+'</select></label>'+fld('points','Points redeemed / credited to backend','number','min="0.01" step="0.01"')+fld('gross','Gross cash-out ($)','number','min="0.01" step="0.01"')+'<label class="field">Notes<textarea name="note" rows="2" placeholder="Optional notes"></textarea></label><p class="muted">Platform-wide cash-out rules calculate the payout and flag exceptional entries for Owner review.</p><button class="primary">Record Cash Out</button></form>');
 const rows=cashouts.map(x=>[
 date(x.created_at),esc(playerName(x.player_id)),esc(gameName(x.game_id)),esc(providers.find(p=>p.id===x.provider_id)?.method||'—'),
 fmt(x.points),money(x.gross_amount),money(x.net_paid),money(x.fee_bearer==='owner'?Math.round((Number(x.gross_amount)*Number(x.fee_rate)/100+Number(x.fee_fixed))*100)/100:0),esc(workerName(x.created_by)),esc(x.review_status),
 esc(x.review_reason||'—')+'<p class="muted">'+esc(x.note||'')+'</p>'+
 (x.review_status==='review_required'&&role==='owner'?'<form id="approve-cashout" class="stack"><input type="hidden" name="cashout_id" value="'+esc(x.id)+'"><input name="reason" placeholder="Owner approval reason" required minlength="3"><button class="primary">Approve Case</button></form>':'')+
 (manager()?'<details><summary>Audited Correction</summary><form id="correct-cashout" class="stack"><input type="hidden" name="cashout_id" value="'+esc(x.id)+'">'+fld('points','Corrected redeemed points','number','min="0.01" step="0.01" value="'+esc(x.points)+'"')+fld('gross','Corrected gross payout','number','min="0.01" step="0.01" value="'+esc(x.gross_amount)+'"')+'<input name="reason" placeholder="Correction reason" required minlength="3"><button class="ghost">Save Correction for Owner Review</button></form></details>':'')
 ]);
 const notes=manager()?panel('Cash-Out Review Notifications',tbl(['Date','Event','Ticket'],cashoutNotifications.slice(0,100).map(x=>[date(x.created_at),esc(x.kind),esc(x.cashout_id.slice(0,12))]))):'';
 const audit=manager()?panel('Cash-Out Audit History',tbl(['Date','Ticket','Action','Actor','Reason'],cashoutAudit.slice(0,100).map(x=>[date(x.created_at),esc(x.cashout_id.slice(0,12)),esc(x.action),esc(workerName(x.actor_id)),esc(x.reason)]))):'';
 return (manager()?panel('Live Backend Credits',backendTickerTable()):'')+notes+form+
 panel('Cash-Out Transactions & Review Status',tbl(['Date','Player','Backend','Method','Point Credit','Gross','Paid','Owner Fee','Worker','Status','Notes / Action'],rows))+audit;
}

function backendPage(){
 const timezone=workspace.closing_timezone||'UTC',cutoff=(workspace.closing_time||'11:00').slice(0,5);
 const reviewForm=x=>role!=='owner'?'':(x.review_status==='review_required'?
 '<form id="review-closing" class="stack"><input type="hidden" name="closing_id" value="'+esc(x.id)+'"><input type="hidden" name="decision" value="approve"><input name="note" placeholder="Owner approval reason" required minlength="3"><button class="primary">Approve Review</button></form>':'')+
 (closings.find(c=>c.game_id===x.game_id)?.id===x.id?'<details><summary>Owner: Correct Latest Balance</summary><form id="review-closing" class="stack"><input type="hidden" name="closing_id" value="'+esc(x.id)+'"><input type="hidden" name="decision" value="correct">'+fld('balance','Corrected backend balance','number','min="0" step="0.01" value="'+esc(x.balance)+'"')+'<input name="note" placeholder="Mandatory correction reason" required minlength="3"><button class="ghost">Correct and Audit</button></form></details>':'');
 return panel('Backend Closing Schedule','<p>Daily cutoff: <b>'+esc(cutoff)+' ('+esc(timezone)+')</b> · 30-minute grace period. First entry establishes a baseline.</p>'+
 '<p class="muted">The actual balance is measured at submission time; the configured daily cutoff determines when a closing becomes due. A late submission or mismatch triggers Owner review.</p>'+
 (role==='manager'?'<form id="closing" class="stack"><label class="field">Backend<select name="game_id" required>'+options(games,'Choose backend',g=>g.name)+'</select></label>'+fld('balance','Actual available backend points','number','min="0" step="0.01"')+'<label class="field">Manager notes<textarea name="note" rows="3" required minlength="3"></textarea></label><button class="primary">Finalize Closing</button></form>':'<p class="muted">Managers finalize closings; Owner reviews and corrects exceptions.</p>'))+
 panel('Live Backend Ticker',backendTickerTable())+
 panel('Closing History',tbl(['Recorded At','Scheduled Cutoff','Backend','Available','Reloaded','Cash-Out Credits','Recorded Loads','Actual Used','Difference','Status','Notes','Owner Action'],closings.map(x=>[
 date(x.created_at),date(x.scheduled_cutoff_at),esc(gameName(x.game_id)),fmt(x.balance),
 x.reload_points===null?'Baseline':fmt(x.reload_points),x.cashout_points===null?'—':fmt(x.cashout_points),
 x.recorded_load_points===null?'—':fmt(x.recorded_load_points),x.actual_used_points===null?'—':fmt(x.actual_used_points),
 x.difference===null?'—':fmt(x.difference),esc(x.review_status)+(x.late_closing?' · Late':''),
 esc(x.manager_note||'—'),reviewForm(x)])))+
 (role==='owner'?panel('Closing Review / Correction Audit',tbl(['Date','Backend Closing','Action','Reason'],closingAudit.map(x=>[date(x.created_at),esc(x.closing_id.slice(0,8)),esc(x.action),esc(x.reason)]))):'');
}


function paymentsPage(){
 const rows=providers.map(p=>{
  const ls=loads.filter(l=>l.provider_id===p.id),cs=cashouts.filter(x=>x.provider_id===p.id);
  const gross=sum(ls,l=>l.payment),fees=sum(ls,l=>Number(l.payment)*Number(l.rate)/100+Number(l.fixed_fee))+sum(cs,x=>x.fee_bearer==='owner'?Math.round((Number(x.gross_amount)*Number(x.fee_rate)/100+Number(x.fee_fixed))*100)/100:0),paid=sum(cs,x=>x.net_paid);
  return[esc(p.company),esc(p.method),ls.length,money(gross),money(fees),money(paid),money(gross-fees-paid)];
 });
 const pending=reconciliations.filter(x=>['mismatch','stale'].includes(x.review_status));
 return panel('Payment Closing — Transaction Totals',tbl(['Company','Method','Loads','Gross','Fees','Cash Outs','Expected Net'],rows))+
 panel('Actual Provider Settlement Reconciliation','<p class="muted">Choose exactly the same settlement period used by your provider. The database calculates expected net automatically; differences require Owner review or a new reconciliation.</p><form id="reconcile" class="stack"><label class="field">Provider<select name="provider_id" required>'+options(providers,'Choose provider',p=>p.company+' / '+p.method)+'</select></label>'+fld('start','Period start','datetime-local')+fld('end','Period end','datetime-local')+fld('actual','Actual net settlement ($)','number','step="0.01"')+'<label class="field">Reconciliation notes<textarea name="note" required minlength="3"></textarea></label><button class="primary">Record Reconciliation</button></form>')+
 panel('Reconciliation Alerts · '+pending.length,(pending.length?'<p class="muted">Mismatch: actual settlement differs. Stale: underlying transaction changed after reconciliation; record a new one.</p>':'<p class="muted">No outstanding settlement reviews.</p>'))+
 panel('Reconciliation History',tbl(['Date','Provider','Period Start','Period End','Expected','Actual','Difference','Status','Notes / Owner Action'],
 reconciliations.map(x=>[
 date(x.created_at),esc(providers.find(p=>p.id===x.provider_id)?.company||'Unknown'),
 date(x.period_start),date(x.period_end),money(x.expected_net),money(x.actual_net),money(x.difference),esc(x.review_status||'—'),
 esc(x.note)+(x.review_reason?' · '+esc(x.review_reason):'')+
 (role==='owner'&&x.review_status==='mismatch'?'<form id="review-payment" class="stack"><input type="hidden" name="reconciliation_id" value="'+esc(x.id)+'"><input name="reason" placeholder="Owner approval reason" required minlength="3"><button class="primary">Approve Difference</button></form>':'')
 ])));
}

function reloadsPage(){return panel('Record Backend Reload','<form id="reload" class="stack"><label class="field">Backend<select name="game_id" required>'+options(games,'Choose backend',g=>g.name)+'</select></label>'+fld('points','Points purchased','number','min="0.01" step="0.01"')+fld('rate','Purchase rate (%)','number','min="0" max="100" step="0.001"')+fld('distributor','Distributor')+'<button class="primary">Record Reload</button></form>')+panel('Reload History',tbl(['Date','Backend','Points','Rate','Cost','Distributor'],reloads.map(r=>[date(r.created_at),esc(gameName(r.game_id)),fmt(r.points),fmt(r.rate)+'%',money(Number(r.points)*Number(r.rate)/100),esc(r.distributor)])))}

function reportsPage(){
 const all=[['day','Daily'],['week','Weekly (Monday start)'],['month','Monthly']];
 const reports=all.map(([bucket,title])=>panel(title+' Financial Report',tbl(
 ['Period','Loads','Payments','Fees','Loaded Points','Bonus','Cash Outs','Reload Cost','Expenses','Net Point Cost','Est. Margin','Cash Flow'],
 (reportSummaries[bucket]||[]).map(x=>[esc(x.period_label),x.loads_count,money(x.gross),money(x.provider_fees),fmt(x.points),fmt(x.bonus_points),
 money(x.cashouts_paid),money(x.reload_cost),money(x.expense_cost),money(x.estimated_point_cost),money(x.estimated_margin),money(x.cash_flow)])))).join('');
 const worker=panel('Loader-wise Performance (All Records)',tbl(['Loader','Role','Players Added','Loads','Gross','Points','Bonus','Cash Outs','Paid'],
 loaderPerformance.map(x=>[esc(x.login_label),esc(x.role_label),x.players_added,x.loads_count,money(x.gross),fmt(x.points),fmt(x.bonus),x.cashouts_count,money(x.cashouts_paid)])));
 return panel('CSV Exports · Full Transaction History','<p class="muted">Exports fetch all permitted records directly from the database in pages, beyond the dashboard preview limit.</p><label class="field">Export dataset<select id="export-dataset"><option value="loads">Loads</option><option value="cashouts">Cash Outs</option><option value="players">Player Wallets</option><option value="closings">Backend Closings</option><option value="reloads">Backend Reloads</option><option value="payment_reconciliations">Payment Reconciliations</option><option value="expenses">Expenses</option><option value="load_correction_audit">Load Correction Audit</option><option value="cashout_audit">Cash-Out Audit</option><option value="closing_audit">Closing Review Audit</option></select></label><button type="button" data-action="export-csv" class="primary">Export All Rows to CSV</button>')+
 reports+worker+'<p class="muted">Financial periods follow the workspace timezone: '+esc(workspace.closing_timezone||'UTC')+'. Estimated margin is not an audited profit statement.</p>';
}

function expensesPage(){return panel('Record Business Expense','<form id="expense" class="stack">'+fld('description','Description')+fld('amount','Amount ($)','number','min="0.01" step="0.01"')+'<button class="primary">Save Expense</button></form>')+panel('Expense History',tbl(['Date','Description','Amount'],expenses.map(x=>[date(x.created_at),esc(x.description),money(x.amount)])))}
function settingsPage(){return (role==='owner'?panel('Platform Cash-Out Settings',(()=>{const rule=cashoutRules[0]||{};return '<form id="cashout-rules" class="stack">'+fld('min_multiplier','Minimum multiplier','number','min="0" step="0.01" value="'+esc(rule.min_multiplier??3)+'"')+fld('max_points','Maximum points (0 = unlimited)','number','min="0" step="0.01" value="'+esc(rule.max_points??0)+'"')+fld('fee_rate','Cash-out fee %','number','min="0" max="100" step="0.001" value="'+esc(rule.fee_rate??0)+'"')+fld('fee_fixed','Fixed cash-out fee','number','min="0" step="0.01" value="'+esc(rule.fee_fixed??0)+'"')+'<label class="field">Fee paid by<select name="fee_bearer"><option value="player" '+(rule.fee_bearer!=='owner'?'selected':'')+'>Player</option><option value="owner" '+(rule.fee_bearer==='owner'?'selected':'')+'>Owner</option></select></label><button class="primary">Save Platform Rules</button></form>'})()):'')+'<div class="two">'+panel('Add Backend','<form id="game" class="stack">'+fld('name','Backend name')+fld('purchase_rate','Default purchase rate (%)','number','min="0" max="100" step="0.001"')+'<button class="primary">Save Backend</button></form>')+panel('Add Payment Provider','<form id="provider" class="stack">'+fld('company','Company')+fld('method','Payment method')+fld('rate','Fee percentage','number','min="0" max="100" step="0.001"')+fld('fixed_fee','Fixed fee ($)','number','min="0" step="0.01"')+'<button class="primary">Save Provider</button></form>')+'</div>'+panel('Workspace Schedule','<p class="muted">Daily cutoff: <b>'+esc(workspace.closing_time||'11:00')+' ('+esc(workspace.closing_timezone||'UTC')+')</b>; 30-minute grace.</p>'+(role==='owner'?'<form id="cutoff" class="stack"><label class="field">Closing time<input type="time" name="cutoff" value="'+esc((workspace.closing_time||'11:00').slice(0,5))+'" required></label><label class="field">Time zone<select name="timezone">'+['UTC','Asia/Karachi','America/New_York','America/Chicago','America/Denver','America/Los_Angeles','Europe/London','Asia/Dubai'].map(t=>'<option value="'+t+'" '+((workspace.closing_timezone||'UTC')===t?'selected':'')+'>'+t+'</option>').join('')+'</select></label><button class="primary">Save Schedule</button></form>':''))+panel('Configured Backends',tbl(['Backend','Purchase Rate'],games.map(g=>[esc(g.name),fmt(g.purchase_rate)+'%'])))+panel('Configured Providers',tbl(['Company','Method','Fee','Fixed'],providers.map(p=>[esc(p.company),esc(p.method),fmt(p.rate)+'%',money(p.fixed_fee)])))}
function teamPage(){if(role!=='owner')return panel('Team','Owner access required.');return panel('Create Manager or Loader','<p class="muted">Username or email-style login ID; no email will be sent. Share the initial password privately.</p><form id="team-create" class="stack">'+fld('login_id','Username or email-style ID')+'<label class="field">Role<select name="role"><option value="manager">Manager</option><option value="worker">Loader</option></select></label>'+fld('password','Initial password','password','minlength="12"')+'<button class="primary">Create account</button></form>')+panel('Manage Team',teamAccounts.map(a=>'<div class="card"><b>'+esc(a.login_id)+'</b> · '+esc(a.role)+' · '+(a.active?'Active':'Disabled')+'<form id="team-reset" class="stack"><input type="hidden" name="user_id" value="'+esc(a.user_id)+'">'+fld('password','New password','password','minlength="12"')+'<button>Reset password</button></form><form id="team-status"><input type="hidden" name="user_id" value="'+esc(a.user_id)+'"><input type="hidden" name="active" value="'+(!a.active)+'"><button>'+(a.active?'Disable':'Enable')+'</button></form></div>').join('')||'<p>No team accounts yet.</p>')}
async function subscribe(){if(channel)await sb.removeChannel(channel);channel=sb.channel('workspace-'+workspace.id).on('postgres_changes',{event:'*',schema:'public',table:'loads',filter:'workspace_id=eq.'+workspace.id},()=>refresh()).on('postgres_changes',{event:'*',schema:'public',table:'players',filter:'workspace_id=eq.'+workspace.id},()=>refresh()).on('postgres_changes',{event:'*',schema:'public',table:'cashouts',filter:'workspace_id=eq.'+workspace.id},()=>refresh()).on('postgres_changes',{event:'*',schema:'public',table:'cashout_notifications',filter:'workspace_id=eq.'+workspace.id},()=>refresh()).on('postgres_changes',{event:'*',schema:'public',table:'load_correction_requests',filter:'workspace_id=eq.'+workspace.id},()=>refresh()).on('postgres_changes',{event:'*',schema:'public',table:'closings',filter:'workspace_id=eq.'+workspace.id},()=>refresh()).on('postgres_changes',{event:'*',schema:'public',table:'reloads',filter:'workspace_id=eq.'+workspace.id},()=>refresh()).on('postgres_changes',{event:'*',schema:'public',table:'payment_reconciliations',filter:'workspace_id=eq.'+workspace.id},()=>refresh()).on('postgres_changes',{event:'*',schema:'public',table:'cashout_audit',filter:'workspace_id=eq.'+workspace.id},()=>refresh()).on('postgres_changes',{event:'*',schema:'public',table:'closing_audit',filter:'workspace_id=eq.'+workspace.id},()=>refresh()).subscribe()}
document.addEventListener('click',async e=>{if(e.target.closest('[data-action="refresh"]')){await refresh();message('Dashboard refreshed.');return}const tabBtn=e.target.closest('[data-tab]');if(tabBtn){tab=tabBtn.dataset.tab;render();return}if(e.target.closest('[data-action="signout"]')){await sb.auth.signOut();if(channel)await sb.removeChannel(channel);workspace=null;boot()}});
document.addEventListener('input',e=>{
 const form=e.target.closest('form#load');
 if(form){
  const payInput=form.querySelector('[name=payment]'),bonusInput=form.querySelector('[name=bonus]');
  const payment=Number(payInput?.value),bonus=Number(bonusInput?.value);
  const preview=document.getElementById('load-preview');
  if(preview)preview.textContent=payInput?.value&&bonusInput?.value!==''&&Number.isFinite(payment)&&payment>0&&Number.isFinite(bonus)&&bonus>=0?
   'Base: '+fmt(payment)+' points · This-load bonus: '+fmt(Math.round(payment*bonus)/100)+' points ('+fmt(bonus)+'%) · Total: '+fmt(Math.round(payment*(1+bonus/100)*100)/100):
   'Enter payment and this transaction’s bonus percentage (type 0 when no bonus).';
  return;
 }
 if(e.target.id!=='wallet-search')return;
 const q=e.target.value.trim().toLowerCase();
 const matched=players.filter(p=>p.name.toLowerCase().includes(q)||p.id.toLowerCase().startsWith(q));
 const target=document.getElementById('wallet-results');
 if(target)target.innerHTML=tbl(['Player','Extra Bonus (Total)','Payments','Loaded','Redeemed','Loads','Cash Outs','Player ID'],walletSummaryRows(matched));
 const history=document.getElementById('wallet-history');
 if(history)history.innerHTML=tbl(['Date','Player','Type','Backend','Method','Paid/Received','Points','Bonus','Status','Note','Worker'],walletHistoryRows(matched.map(p=>p.id)));
});

document.addEventListener('change',e=>{if(e.target.closest('form#load'))e.target.dispatchEvent(new Event('input',{bubbles:true}))});
document.addEventListener('submit',async e=>{const f=e.target,form=f.id;if(!['auth','workspace','player','game','provider','load','reload','expense','closing','cashout','approve-cashout','cashout-rules','correct-cashout','team-create','team-reset','team-status','cutoff','reconcile','load-correction','review-load-correction','review-closing','review-payment'].includes(form))return;e.preventDefault();if(busy)return;const d=Object.fromEntries(new FormData(f));const submitter=e.submitter;busy=true;f.querySelectorAll('button').forEach(b=>b.disabled=true);
try{if(['team-create','team-reset','team-status'].includes(form)){if(role!=='owner')throw Error('Owner only');const body={workspace_id:workspace.id,action:form==='team-create'?'create':form==='team-reset'?'reset_password':'set_active',...d};if(form==='team-status')body.active=d.active==='true';const result=await sb.functions.invoke('manage-team',{body});if(result.error)throw result.error;if(result.data?.error)throw Error(result.data.error);await refresh();message('Team account updated.');return}if(form==='auth'){if(Date.now()<authCooldown)throw Error('Please wait before retrying.');const loginId=String(d.email||'').trim();const isOwnerEmail=/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(loginId);const expectedEmail=isOwnerEmail?loginId.toLowerCase():await teamEmail(loginId);const res=submitter?.value==='signup'?await sb.auth.signUp({email:loginId,password:d.password,emailRedirectTo:'https://sweep-calculator-02.vercel.app/cloud.html'}):await sb.auth.signInWithPassword({email:expectedEmail,password:d.password});if(!res.error&&res.data?.user&&res.data.user.email?.toLowerCase()!==expectedEmail){await sb.auth.signOut();throw Error('Login identity mismatch. Please contact the Owner.')};if(res.error)throw res.error;if(!res.data.session){message('Check your inbox to confirm your email, then sign in.');return}await boot();return}
if(form==='workspace'){const r=await sb.rpc('create_my_workspace',{workspace_name:d.name});if(r.error)throw r.error;await boot();return}
if(form==='load'){if(String(d.bonus??'').trim()==='')throw Error('Enter a bonus percent for this load (0 is allowed).');const r=await sb.rpc('record_load',{p_player:d.player_id,p_game:d.game_id,p_provider:d.provider_id,p_payment:Number(d.payment),p_note:d.note||'',p_bonus:Number(d.bonus)});if(r.error)throw r.error;await refresh();message('Load saved with manually entered transaction bonus.');return}
if(form==='load-correction'){if(String(d.bonus??'').trim()==='')throw Error('Enter the corrected bonus percent.');const r=await sb.rpc('submit_load_correction',{p_load:d.load_id,p_player:d.player_id,p_game:d.game_id,p_provider:d.provider_id,p_payment:Number(d.payment),p_note:d.note||'',p_reason:d.reason,p_bonus:Number(d.bonus)});if(r.error)throw r.error;await refresh();message(r.data==='applied'?'Correction applied and audited.':'Correction sent for Manager approval.');return}
if(form==='review-load-correction'){if(!manager())throw Error('Manager only');const r=await sb.rpc('review_load_correction',{p_request:d.request_id,p_approve:submitter?.value==='approve',p_review_note:d.note});if(r.error)throw r.error;await refresh();message('Correction request reviewed.');return}
if(form==='review-payment'){if(role!=='owner')throw Error('Owner only');const r=await sb.rpc('review_payment_reconciliation',{p_reconciliation:d.reconciliation_id,p_reason:d.reason});if(r.error)throw r.error;await refresh();message('Settlement difference approved.');return}
if(form==='review-closing'){if(role!=='owner')throw Error('Owner only');const r=await sb.rpc('review_backend_closing',{p_closing:d.closing_id,p_corrected_balance:d.decision==='correct'?Number(d.balance):null,p_reason:d.note});if(r.error)throw r.error;await refresh();message('Closing review saved and audited.');return}
if(form==='reconcile'){if(!manager())throw Error('Manager/Owner only');const x=await sb.rpc('record_payment_reconciliation',{p_provider:d.provider_id,p_start:new Date(d.start).toISOString(),p_end:new Date(d.end).toISOString(),p_actual:Number(d.actual),p_note:d.note});if(x.error)throw x.error;await refresh();message('Provider reconciliation recorded.');return}
if(form==='cutoff'){if(role!=='owner')throw Error('Owner only');const x=await sb.rpc('update_workspace_schedule',{p_workspace:workspace.id,p_cutoff:d.cutoff,p_timezone:d.timezone});if(x.error)throw x.error;workspace.closing_time=d.cutoff;workspace.closing_timezone=d.timezone;render();message('Closing schedule saved.');return}
if(form==='cashout-rules'){if(role!=='owner')throw Error('Owner only');const result=await sb.rpc('update_platform_cashout_rules',{p_workspace:workspace.id,p_min_multiplier:Number(d.min_multiplier),p_max_points:Number(d.max_points),p_fee_rate:Number(d.fee_rate),p_fee_fixed:Number(d.fee_fixed),p_fee_bearer:d.fee_bearer});if(result.error)throw result.error;await refresh();message('Cash-out rules saved.');return}
if(form==='cashout'){const r=await sb.rpc('record_cashout',{p_player:d.player_id,p_game:d.game_id,p_provider:d.provider_id,p_points:Number(d.points),p_gross:Number(d.gross),p_note:d.note||''});if(r.error)throw r.error;await refresh();message('Cash-out recorded; review status calculated.');return}
if(form==='correct-cashout'){if(!manager())throw Error('Manager/Owner only');const r=await sb.rpc('correct_cashout',{p_cashout:d.cashout_id,p_points:Number(d.points),p_gross:Number(d.gross),p_reason:d.reason});if(r.error)throw r.error;await refresh();message('Correction audited; owner review required.');return}
if(form==='approve-cashout'){if(role!=='owner')throw Error('Owner only');const r=await sb.rpc('approve_cashout',{p_cashout:d.cashout_id,p_reason:d.reason});if(r.error)throw r.error;await refresh();message('Owner approval recorded.');return}
if(form==='closing'){const r=await sb.rpc('finalize_backend_closing',{p_game:d.game_id,p_balance:Number(d.balance),p_note:d.note});if(r.error)throw r.error;await refresh();message('Closing finalized.');return}
let row={workspace_id:workspace.id},tableName=form;
if(form==='player'){const normalized=String(d.name||'').trim().replace(/\s+/g,' ').toLowerCase();if(!normalized)throw Error('Player name is required.');if(players.some(p=>String(p.name||'').trim().replace(/\s+/g,' ').toLowerCase()===normalized))throw Error('Duplicate player name/ID. Open the existing wallet instead.');Object.assign(row,{name:d.name.trim(),created_by:user.id});tableName='players';}
if(form==='game')Object.assign(row,{name:d.name,purchase_rate:Number(d.purchase_rate)}),tableName='games';
if(form==='provider')Object.assign(row,{company:d.company,method:d.method,rate:Number(d.rate),fixed_fee:Number(d.fixed_fee)}),tableName='providers';
if(form==='expense')Object.assign(row,{description:d.description,amount:Number(d.amount),created_by:user.id}),tableName='expenses';
if(form==='reload')Object.assign(row,{game_id:d.game_id,points:Number(d.points),rate:Number(d.rate),distributor:d.distributor,created_by:user.id}),tableName='reloads';

const result=await sb.from(tableName).insert(row);if(result.error)throw result.error;await refresh();message('Saved successfully in cloud.');
}catch(err){const msg=err.message||String(err);if(form==='auth'&&/after \d+ seconds|rate limit|too many requests/i.test(msg)){const seconds=Number(msg.match(/after (\d+) seconds/)?.[1]||60);authCooldown=Date.now()+seconds*1000}message(msg)}finally{busy=false;if(f.isConnected)f.querySelectorAll('button').forEach(b=>b.disabled=false)}});

async function exportFullCsv(){
 if(!manager())throw Error('Manager or Owner required');
 const allowed=['loads','cashouts','players','closings','reloads','payment_reconciliations','expenses','load_correction_audit','cashout_audit','closing_audit'];
 const dataset=document.getElementById('export-dataset')?.value;
 if(!allowed.includes(dataset))throw Error('Invalid export dataset');
 const table=dataset==='cashouts'?'cashouts_visible':dataset;
 const result=[];let start=0;
 while(true){
  const page=await sb.from(table).select('*').eq('workspace_id',workspace.id).order('created_at',{ascending:true}).range(start,start+499);
  if(page.error)throw page.error;
  const rows=page.data||[];result.push(...rows);
  message('Preparing '+dataset+' CSV: '+result.length+' rows');
  if(rows.length<500)break;
  start+=500;
 }
 const columns=Array.from(new Set(result.flatMap(row=>Object.keys(row))));
 const safeCell=value=>{
  let s=value===null||value===undefined?'':typeof value==='object'?JSON.stringify(value):String(value);
  if(/^[=+\-@\t\r]/.test(s))s="'"+s;
  return '"'+s.replace(/"/g,'""')+'"';
 };
 const csv=[columns.map(safeCell).join(','),...result.map(row=>columns.map(k=>safeCell(row[k])).join(','))].join('\r\n');
 const blob=new Blob(['\ufeff'+csv],{type:'text/csv;charset=utf-8'});
 const url=URL.createObjectURL(blob);
 const link=document.createElement('a');
 link.href=url;link.download='sweep-'+dataset+'-'+new Date().toISOString().slice(0,10)+'.csv';document.body.appendChild(link);link.click();link.remove();
 setTimeout(()=>URL.revokeObjectURL(url),1000);
 message('Export prepared: '+result.length+' rows from '+dataset+'.');
}
document.addEventListener('click',async e=>{
 const control=e.target.closest('[data-action="export-csv"]');
 if(!control)return;
 if(busy)return;
 busy=true;control.disabled=true;
 try{await exportFullCsv()}catch(err){message(err.message||String(err))}
 finally{busy=false;if(control.isConnected)control.disabled=false}
});

sb.auth.onAuthStateChange(event=>{if(event==='SIGNED_OUT')boot()});
boot();