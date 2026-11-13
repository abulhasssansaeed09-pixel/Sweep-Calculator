# Owner-managed team accounts — approved requirements (2026-11-13)

## Final owner decision (supersedes invitation workflow)
- No email invitations, delivery, confirmation or OTP. Email, when provided, is **only a login identifier**, not a communication channel.
- Owner manually creates Manager or Loader accounts, supplying **either** a username (e.g. Hassan@101) **or** an email-style identifier. Either is sufficient; both may be supplied.
- Each account receives a stable unique internal UUID; username/email identifiers must be normalized and unique within the chosen authentication namespace.
- Owner sets an initial password and can reset it, activate/deactivate accounts, and view their role and status. Existing passwords must never be displayed or stored in plaintext.
- One public login page; after authentication, server-verified membership role determines owner/manager/loader dashboard. Managers and loaders cannot create or administer accounts.
- Account deactivation must be enforced on **every** protected database operation, not just login or UI, including previously issued sessions.
- No owner credentials, service-role keys, or privileged account administration API in browser code.

## Implementation guidance
- Supabase Auth expects a valid email or phone identity. A username-only login must be handled through a **secure server-side identity mapping**, possibly with a reserved synthetic email namespace for Auth. Synthetic addresses must never be used for outgoing mail, and the system must not rely on delivery to them.
- Privileged Edge Functions verify caller JWT and active owner membership, create auth identities with the Supabase Admin API, assign workspace membership and role, reset passwords, and activate/deactivate. Use rate limits, strong password policy, audit logs and rollback/reconciliation for partial failures.
- Authenticate by username/email identifier through a server-side resolver that does not reveal whether a user exists, then use Supabase Auth for password verification. Do not build custom password hashing in frontend.
- Ensure identifier collision handling, duplicate account prevention, role validation, cross-workspace authorization, reset session invalidation and immediate access revocation.
- Keep current production memberships and data intact. Do not deploy until integration tests and security checks pass.

## Acceptance tests
1. Owner creates manager using username only; creates loader using email-style identifier only; both can log in without receiving email.
2. Duplicate identifiers rejected; UUID remains stable across identifier edits.
3. Manager/loader cannot create, reset, disable or change other accounts by direct API calls.
4. Disabled account denied both fresh login and database requests with an existing session.
5. Owner password reset takes effect; previous password rejected; existing sessions revoked or blocked.
6. User from another workspace cannot administer team members; audit logs include actor, target, action and timestamp.
7. One login page routes roles correctly; final owner cannot accidentally be disabled.

## Status
Approved specification only. Server endpoints, migrations, UI and tests are not yet implemented. Production unchanged.
