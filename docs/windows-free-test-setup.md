# Free local testing — Windows quick start

No payment, Pro subscription, or Supabase cloud branch required.

## Prerequisites (one-time)
1. Install **Docker Desktop** for Windows from https://www.docker.com/products/docker-desktop/ and enable WSL 2 if prompted. Open Docker Desktop and wait for the engine to show **Running**.
2. Install **Node.js LTS** from https://nodejs.org/ if `node --version` does not work.
3. Install **Git** from https://git-scm.com/downloads/win if `git --version` does not work.
4. Clone the private Sweep Calculator repository using GitHub Desktop or Git (requires your GitHub login). Switch to branch `feature/approved-workflows-2026-11-12`.
5. Open **PowerShell** in the repository folder.

## Run the free checks
```powershell
node --version
docker info
node --test tests/team-security.test.mjs
node --test tests/cashout-free.test.mjs
npm install --no-save supabase
npx supabase start
npx supabase status
```

**Stop here until local baseline schema is installed.** The repo's feature migrations depend on workspace, membership, games and other base tables. Do not apply the team migration to an empty database.

## What to send back
Share the output of `docker info` (omit sensitive machine information), `node --test tests/team-security.test.mjs`, and `npx supabase status`. **Do not share** the service-role key, access tokens, passwords, or `.env` files.

## Safety
- Never run `supabase db push` against the production project during testing.
- Keep all testing local; never use production keys or production users.
- GitHub Actions also runs static Node tests on dev-branch pushes, subject to your GitHub account's free-tier quotas.
- Local Auth/RLS end-to-end tests are not yet executable until the baseline schema and test fixtures are created.
