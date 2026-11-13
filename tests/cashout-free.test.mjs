// Run with: node --test tests/cashout-free.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const js=readFileSync(new URL('../cloud-v2.js',import.meta.url),'utf8');
const sql=readFileSync(new URL('../migrations/20261112_cashout_workflow.sql',import.meta.url),'utf8');
test('cloud JS parses',()=>assert.doesNotThrow(()=>new Function(js.replace(/^import[^\n]*\n/,''))));
const checks={
 'owner-only rule read policy':/cashout_rules_owner_read/.test(sql),
 'cashout direct writes disabled':!/(?:create policy)\s+cashouts_(?:insert|update|delete)/i.test(sql),
 'workspace-scoped cashout':/x\.workspace_id=w/.test(sql),
 'manager or owner correction':/m\.role in \('owner','manager'\)/.test(sql),
 'owner-only approval':/m\.role='owner'/.test(sql),
 'cashout fee rate snapshot':/coalesce\(rules\.fee_rate,0\)/.test(sql),
 'last load matches player and backend':/l\.player_id=p_player and l\.game_id=p_game/.test(sql),
 'correction audits before and after':/to_jsonb\(old_row\),to_jsonb\(new_row\)/.test(sql),
 'repeat review notifications permitted':!/unique\(cashout_id,kind\)/.test(sql),
 'null rules rejected':/p_fee_bearer is null/.test(sql),
 'worker cannot fetch owner rule settings':/name!=='cashout_rules'\|\|role==='owner'/.test(js),
 'worker UI has no correction control':/manager\(\)\?'<form id="correct-cashout"/.test(js),
 'owner UI approval gated':/review_status==='review_required'&&role==='owner'/.test(js),
 'owner rule RPC present':/rpc\('update_cashout_rules'/.test(js)
};
for(const [name,passed] of Object.entries(checks))test(name,()=>assert.ok(passed));
