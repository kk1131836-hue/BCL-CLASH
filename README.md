# BCL Season 3 Live Auction

This version is designed for the workflow you requested: a captain presses **BID**, the database validates it, and every connected screen receives the updated captain name and bid amount in real time.

## Tournament rules built in
- 10 captain/team records, initially 10,000 credits each
- Tier 1 base: 3,000 credits
- Tier 2 (MOD) base: 1,500 credits
- Tier 3 (21Star non-mod + Uncapped) base: 1,000 credits
- Maximum 4 auction players per team (captain is already included in the team size of 5)
- Admin can add up to 50 players, select the live player, and close as SOLD/UNSOLD
- Realtime bid feed, purse balances, team rosters, auction activity
- Captain/team selection is open in this starter version. It is NOT a secure captain login; see security note.

## Important: this is a hosted-ready app, not a deployed public URL
The site needs a Supabase project to share live state between different devices. The ZIP does not contain your Supabase credentials and is not already hosted.

## Setup shared live database
1. Create a free project at https://supabase.com/.
2. Open **SQL Editor** in the Supabase dashboard.
3. Open `supabase_setup.sql`, copy all SQL, and run it.
4. IMPORTANT: change the seeded admin password. In SQL Editor run:
   ```sql
   update public.auction_settings
   set admin_password_hash = crypt('YOUR-STRONG-NEW-PASSWORD', gen_salt('bf'))
   where id=1;
   ```
   Keep this password private.
5. In Supabase **Project Settings → API** (or Connect), copy the Project URL and the public anon/publishable key. Never use the service-role/secret key in browser code.
6. Open `index.html` in a browser, paste the Project URL and public key into the setup prompt. That configuration is saved in that browser. The same frontend can be deployed to Render/Netlify/Vercel.
7. To deploy on Render: create a new **Static Site**, connect a GitHub repository containing `index.html`, set the publish directory to the root (`.`), then deploy. Alternatively use Netlify Drop for a quick static deployment. Keep `supabase_setup.sql` and `README.md` in the repo for reference.

## How the live bidding display works
- Admin unlocks Admin panel with the configured password.
- Admin adds players and chooses “Select next available player”. The player status becomes LIVE.
- Captains on their own phones select their team, choose +100/+250/+500/+1000 or enter a custom bid, and press BID.
- The SQL function checks that the player is live, the bid is higher than the current bid and at least the tier base price, the captain has enough purse, and the team has fewer than 4 bought players.
- The database records the bid and emits a Realtime update. Every connected browser shows a message like “Captain 1 bid 3,500 credits for Player 1”, and the current amount/leader update.
- Admin marks the live player SOLD or UNSOLD.

## Security limitation to fix before an official tournament
This is a working starter, not a fully hardened competitive production system. Captain identity is currently chosen from a dropdown and isn't authenticated; a user could bid under another captain's name. The admin password protects admin RPC calls, but the public RPC is callable by clients that know the password. Before an official event, add Supabase Auth (one account per captain), enforce captain-to-user mapping in database functions, and use server-side authorization. Do not share the admin password.


## Visual theme
The interface uses a Clash of Clans-inspired fantasy village look: forest-green panels, stone/wood borders, gold buttons and shields, with responsive mobile layout. It does not bundle official Supercell art assets.
