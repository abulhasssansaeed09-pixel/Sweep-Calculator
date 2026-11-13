# Free local integration testing (no paid Supabase branch)

Requires Docker Desktop (running), Node.js 20+, and Supabase CLI. No Pro plan or paid cloud resources.

1. Clone the private repository and switch to `feature/approved-workflows-2026-11-12`.
2. Install CLI locally: `npm install --no-save supabase` (do not use global npm install).
3. Run `npx supabase start`. This launches local Postgres/Auth/API/Studio using Docker. The first run downloads images.
4. Run `npx supabase status` and use **local** API URL and anon key. Never point integration tests at the production project.
5. Apply existing base schema/migrations in their correct order. The repository currently contains feature migrations, not a verified complete baseline schema snapshot. **Do not run team migration alone against an empty database**; its workspace/membership dependencies must exist first.
6. Deploy local function with `npx supabase functions serve manage-team --env-file supabase/.env.local`. Store local-only secrets in ignored `.env.local`, never GitHub.
7. Execute `node --test tests/team-security.test.mjs` for static checks. Run full integration tests only after baseline and function are running.

## Required real tests before release
- Create owner; create manager via username and loader via email-style identifier, no email delivery.
- Verify both log in through same URL; owner-only operations reject worker/manager JWTs.
- Reset password; old password fails; existing access token cannot SELECT/INSERT/RPC; new login succeeds.
- Disable account; old JWT blocked by RLS and definer RPC; re-enable; old JWT remains blocked; new login works.
- Verify cross-workspace owner cannot administer another workspace.
- Verify legacy memberships still work until migrated.
- Test simultaneous duplicate login ID creation and failure rollback.
- Ensure migration is applied only to local environment and never to production automatically.

## Known release risks
- Browser sign-up remains available for new workspace owners; only employee creation is owner-managed.
- Session cutoff relies on `auth.sessions` and JWT `session_id`; integration tests must confirm these semantics.
- The existing production `finalize_backend_closing` security-definer RPC needs its own active-team check before release.
- Supabase Auth may send emails for unrelated owner signup/recovery; the owner-managed team creation flow does not send invitations.

## Costs
Docker, local Supabase CLI and GitHub test code are free. Your computer provides the compute. Free-tier limits still apply to production hosting.
