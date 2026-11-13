# Owner-managed team invitations — approved design (2026-11-13)

## Decision
- Each newly registered independent business owner creates a workspace; `create_my_workspace` assigns them the owner role.
- Existing invited users must **not** create another owner workspace accidentally.
- Only workspace owner can manually invite unlimited managers/loaders (subject to service quotas).
- Owner enters employee email and role (manager or worker). Employee sets their own password using a one-time, expiring email invitation. No shared or owner-set passwords.
- A manager/loader must never be able to invite, promote, demote, remove, or transfer members.

## Implementation security contract
1. Supabase Edge Function authenticated with the caller JWT. Server verifies owner membership for the target workspace using a privileged server-side client. Do not put a service-role key in cloud HTML or browser JavaScript.
2. Edge Function validates email, role allowlist (`manager`, `worker`), workspace, existing membership, duplicates, and invite rate limits. Log invite, acceptance, revocation, and role changes.
3. Invite record stores workspace, invited email, intended role, status, expiry, inviter; use hashed single-use tokens if building custom links. Prefer Supabase Auth admin invitation APIs where supported; configure redirect URLs to the deployed application.
4. Acceptance binds the invited email and authenticated Supabase user ID to the designated workspace membership transactionally. No user-controlled role/workspace fields can grant access.
5. Owner can view pending invitations, resend expired invitations, revoke pending invitations, deactivate members and change worker/manager roles with server-side checks. Prevent removing the final owner.
6. For new signups, only an uninvited user with no memberships may create a workspace. Invitation recipients see invitation acceptance instead of workspace creation.
7. All workspace tables enforce membership and role in database RLS; hiding UI buttons is not security.
8. Avoid exposing invite tokens, credentials, service keys, or full auth payloads in logs.
9. Keep existing memberships and workspace data untouched during migration.

## Tests required before release
- Owner invite manager and worker; invited employee sets password and sees correct dashboard.
- Worker/manager cannot call invite endpoint, even via forged HTTP requests.
- Invite cannot be accepted by a different email or reused after acceptance/revocation/expiry.
- Cross-workspace invitation and role escalation denied.
- Duplicate invites, existing accounts, email send failure, expired link, revoked user and owner signout handled.
- Existing owner remains owner; no accidental second owner created.

## Status
Requirements approved. This document is not a deployed invitation service. Edge Function, invite persistence, owner UI, RLS, email delivery and integration tests remain to implement. Production is unchanged.
