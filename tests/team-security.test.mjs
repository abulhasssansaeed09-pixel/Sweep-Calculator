// Static security regression tests; run: node --test tests/team-security.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const read=p=>readFileSync(new URL('../'+p,import.meta.url),'utf8');
const js=read('cloud-v2.js'),edge=read('supabase/functions/manage-team/index.ts');
const team=read('migrations/20261113_team_accounts.sql');
const cash=read('migrations/20261112_cashout_workflow.sql');
const cases={
 'owner-only team administration':edge.includes("membership?.role!=='owner'"),
 'manager/worker roles only':edge.includes("['manager','worker'].includes(role)"),
 'password minimum enforced':edge.includes('password.length<12'),
 'team account creation rollback':edge.includes('admin.auth.admin.deleteUser(id)'),
 'client does not expose service role key':!js.includes('SERVICE_ROLE_KEY'),
 'hashed login mapping on server':edge.includes("crypto.subtle.digest('SHA-256'"),
 'hashed login mapping on client':js.includes("crypto.subtle.digest('SHA-256'"),
 'username-only login uses synthetic identity':js.includes("if(!d.email.includes('@'))return sb.auth.signInWithPassword({email:await teamEmail(d.email)"),
 'browser handles async login mapping':js.includes('email:await teamEmail(d.email)'),
 'CORS preflight':edge.includes("req.method==='OPTIONS'"),
 'owner UI has create control':js.includes('id="team-create"'),
 'owner UI has reset control':js.includes('id="team-reset"'),
 'owner UI has activation control':js.includes('id="team-status"'),
 'legacy members preserved':team.includes('or not exists ('),
 'inactive team member denied':team.includes('t.active=true'),
 'RLS restrictive guard':team.includes('as restrictive for all'),
 'password reset invalidates sessions':edge.includes('session_valid_after:new Date().toISOString()'),
 'RLS checks auth session creation':team.includes('from auth.sessions sess')&&team.includes('sess.created_at>t.session_valid_after'),
 'account status invalidates sessions':edge.includes('active:input.active,session_valid_after:'),
 'RPCs check active membership':(cash.match(/public\.team_access_active\(/g)||[]).length>=4
};
for(const [name,pass] of Object.entries(cases))test(name,()=>assert.ok(pass));
test('browser code parses',()=>assert.doesNotThrow(()=>new Function(js.replace(/^import[^\n]*\n/,''))));
