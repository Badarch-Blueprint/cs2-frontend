# Testing the Admin Panel

A short walkthrough for getting admin access and exercising the end-to-end flow (teams → tournaments → matches → veto → server pool).

## 1. Start the stack

From `cs2-tournament-backend/`:

```bash
# Postgres
docker compose up -d postgres

# Backend (port 3000)
cd backend
cp .env.example .env   # first time only; edit values
npm install
npm run start:dev

# Frontend (port 4200) — new terminal
cd frontend
npm install
npm start
```

The backend reads `FRONTEND_URL` / `BACKEND_URL` from `backend/.env`. The Steam callback
redirects to `${FRONTEND_URL}/auth/callback?token=...`.

## 2. Become an admin

The `PATCH /api/users/:id/role` endpoint requires an existing admin, so the very first
admin must be promoted another way. Pick one:

### Option A — Bootstrap via env (recommended)

Add your 64-bit SteamID to `backend/.env` (see `backend/.env.example`):

```bash
BOOTSTRAP_ADMIN_STEAM_IDS=76561198000000000
```

Supports multiple IDs separated by commas. On the next Steam login the user is created
(or updated) with `role = 'admin'` automatically. No DB edit needed. Remove the variable
once you no longer need it.

Don't know your SteamID? Log in once, then look at the `users` table or
<https://steamid.io/>.

### Option B — Manual SQL

After logging in once via Steam, promote yourself:

```bash
docker compose exec postgres psql -U postgres -d cs2tournament \
  -c "UPDATE users SET role='admin' WHERE steam_name='<your steam name>';"
```

Or by `steamId`: `WHERE "steamId"='<your 64-bit steamid>'`.

After either option, **refresh the frontend** — the `Admin` link appears in the sidebar,
guarded by `frontend/src/app/core/guards/auth.guard.ts#adminGuard`.

## 3. Happy-path test flow inside `/admin`

1. **Teams tab** → create two or more teams (name + short tag like `NAVI`).
2. **Tournaments tab** → create a tournament (format = `groups` is easiest).
3. **Matches tab** → fill in:
   - `Match ID` (e.g. `ga-r1-m1`)
   - Team 1 / Team 2 (must differ)
   - Best of 1/3/5
   - Optionally attach a tournament
   - Optionally toggle **Showmatch**

   Click **Create match**.
4. In the match row click **Start veto** → opens `/match/<id>/veto` where you can drive
   the pick/ban flow. Admins can always act; otherwise only the team captain of the
   current turn can pick/ban.
5. **Users tab** → change another user's role from the select on the right.
6. **Servers tab** → **Refresh** queries the CS2 host at `CS2_HOST_URL`. You should see
   active slots, the queue, and the utilization stat cards. If nothing comes back, check
   `cs2-server-manager.sh` and the `CS2_HOST_URL` in `backend/.env`.

## 4. Backend-only smoke test (no UI)

Once logged in, open DevTools → `Application → Local Storage` and copy the value of
`cs2_token`. Then:

```bash
TOKEN="<paste jwt>"

# whoami
curl -H "Authorization: Bearer $TOKEN" http://localhost:3000/api/auth/me

# create a team
curl -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Team A","tag":"TA"}' \
  http://localhost:3000/api/teams

# create a match (substitute real team UUIDs)
curl -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "matchId":"ga-r1-m1",
    "team1Id":"<uuid>",
    "team2Id":"<uuid>",
    "bestOf":1
  }' \
  http://localhost:3000/api/matches
```

## 5. Troubleshooting

- **"Admin" link not showing:** `auth.user().role` must equal `admin`. Log out + back in
  after updating the role in the DB; the role is baked into the JWT and also refetched
  from `/auth/me` on boot.
- **Steam login redirects to the wrong host:** check `FRONTEND_URL` in `backend/.env`
  matches the address you're actually visiting.
- **CS2 servers tab says "not reachable":** `CS2_HOST_URL` must point at the
  `cs2-server-manager.sh` HTTP control plane on the Ubuntu host.
