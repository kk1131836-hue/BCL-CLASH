-- BCL Season 3 Live Auction: run this whole file in Supabase SQL Editor.
-- IMPORTANT: change the admin password below before the event.
create extension if not exists pgcrypto;

create table if not exists public.captains (
 id uuid primary key default gen_random_uuid(),
 name text not null,
 budget integer not null default 10000 check (budget >= 0),
 created_at timestamptz not null default now()
);
create table if not exists public.players (
 id uuid primary key default gen_random_uuid(),
 name text not null unique,
 tier integer not null check (tier in (1,2,3)),
 th_level text not null default '',
 note text not null default '',
 status text not null default 'upcoming' check(status in ('upcoming','live','sold','unsold')),
 highest_bid integer not null default 0 check(highest_bid >= 0),
 highest_bidder_id uuid references public.captains(id),
 winner_id uuid references public.captains(id),
 final_price integer not null default 0,
 queue_order bigserial,
 created_at timestamptz not null default now()
);
create table if not exists public.auction_events (
 id uuid primary key default gen_random_uuid(),
 type text not null,
 message text not null,
 player_id uuid references public.players(id) on delete set null,
 captain_id uuid references public.captains(id) on delete set null,
 amount integer,
 created_at timestamptz not null default now()
);
create table if not exists public.auction_settings (
 id integer primary key default 1 check(id=1),
 current_player_id uuid references public.players(id) on delete set null,
 budget integer not null default 10000,
 admin_password_hash text not null
);
insert into public.auction_settings(id,budget,admin_password_hash)
values(1,10000,crypt('CHANGE-ME-BCL-ADMIN-PASSWORD',gen_salt('bf')))
on conflict(id) do nothing;

-- Seed 10 teams. Rename them in the Admin panel after setup.
insert into public.captains(name,budget)
select 'Captain '||n,10000 from generate_series(1,10) n
where not exists(select 1 from public.captains);

alter table public.captains enable row level security;
alter table public.players enable row level security;
alter table public.auction_events enable row level security;
alter table public.auction_settings enable row level security;

drop policy if exists "public read captains" on public.captains;
create policy "public read captains" on public.captains for select to anon, authenticated using (true);
drop policy if exists "public read players" on public.players;
create policy "public read players" on public.players for select to anon, authenticated using (true);
drop policy if exists "public read events" on public.auction_events;
create policy "public read events" on public.auction_events for select to anon, authenticated using (true);
drop policy if exists "public read settings" on public.auction_settings;
create policy "public read settings" on public.auction_settings for select to anon, authenticated using (true);
-- No direct table writes are granted by RLS; all writes go through validated RPC functions.

create or replace function public.admin_login_check(admin_password text)
returns boolean language plpgsql security definer set search_path=public as $$
declare good boolean;
begin
 select crypt(admin_password, admin_password_hash)=admin_password_hash into good
 from public.auction_settings where id=1;
 if not coalesce(good,false) then raise exception 'Invalid admin password'; end if;
 return true;
end $$;

create or replace function public.admin_select_player(player_uuid uuid, admin_password text)
returns boolean language plpgsql security definer set search_path=public as $$
begin
 perform public.admin_login_check(admin_password);
 if not exists(select 1 from public.players where id=player_uuid and status in ('upcoming','unsold','live')) then
   raise exception 'Player not available';
 end if;
 update public.players set status='upcoming' where status='live' and id<>player_uuid;
 update public.players set status='live' where id=player_uuid;
 update public.auction_settings set current_player_id=player_uuid where id=1;
 insert into public.auction_events(type,message,player_id) select 'LIVE',name||' is now LIVE in the auction',id from public.players where id=player_uuid;
 return true;
end $$;

create or replace function public.place_auction_bid(player_uuid uuid, captain_uuid uuid, bid_amount integer)
returns boolean language plpgsql security definer set search_path=public as $$
declare p public.players%rowtype; c public.captains%rowtype; base_price integer; spent_amount integer; roster_count integer; minimum_bid integer;
begin
 select * into p from public.players where id=player_uuid for update;
 if not found or p.status<>'live' then raise exception 'This player is not live in the auction'; end if;
 select * into c from public.captains where id=captain_uuid;
 if not found then raise exception 'Captain/team not found'; end if;
 base_price:=case p.tier when 1 then 3000 when 2 then 1500 else 1000 end;
 minimum_bid:=greatest(base_price,p.highest_bid+1);
 if bid_amount<minimum_bid then raise exception 'Bid must be at least %',minimum_bid; end if;
 select coalesce(sum(final_price),0),count(*) into spent_amount,roster_count from public.players where status='sold' and winner_id=captain_uuid;
 if roster_count>=4 then raise exception 'Your team already has 4 auction players'; end if;
 if bid_amount>c.budget-spent_amount then raise exception 'Bid exceeds your remaining purse'; end if;
 update public.players set highest_bid=bid_amount,highest_bidder_id=captain_uuid where id=player_uuid;
 insert into public.auction_events(type,message,player_id,captain_id,amount)
 values('BID',c.name||' bid '||to_char(bid_amount,'FM999,999,999')||' credits for '||p.name,player_uuid,captain_uuid,bid_amount);
 return true;
end $$;

create or replace function public.admin_close_player(player_uuid uuid, final_status text, admin_password text)
returns boolean language plpgsql security definer set search_path=public as $$
declare p public.players%rowtype; c public.captains%rowtype; spent_amount integer; roster_count integer;
begin
 perform public.admin_login_check(admin_password);
 if final_status not in ('sold','unsold') then raise exception 'Status must be sold or unsold'; end if;
 select * into p from public.players where id=player_uuid for update;
 if not found or p.status<>'live' then raise exception 'Only the live player can be closed'; end if;
 if final_status='sold' then
   if p.highest_bidder_id is null then raise exception 'No bids recorded; mark player UNSOLD'; end if;
   select * into c from public.captains where id=p.highest_bidder_id;
   select coalesce(sum(final_price),0),count(*) into spent_amount,roster_count from public.players where status='sold' and winner_id=c.id;
   if roster_count>=4 then raise exception 'Winning captain already has 4 auction players'; end if;
   if p.highest_bid>c.budget-spent_amount then raise exception 'Winner no longer has enough purse'; end if;
   update public.players set status='sold',winner_id=c.id,final_price=highest_bid where id=player_uuid;
   insert into public.auction_events(type,message,player_id,captain_id,amount) values('SOLD',p.name||' SOLD to '||c.name||' for '||to_char(p.highest_bid,'FM999,999,999')||' credits',p.id,c.id,p.highest_bid);
 else
   update public.players set status='unsold',winner_id=null,final_price=0 where id=player_uuid;
   insert into public.auction_events(type,message,player_id) values('UNSOLD',p.name||' marked UNSOLD',p.id);
 end if;
 update public.auction_settings set current_player_id=null where id=1 and current_player_id=player_uuid;
 return true;
end $$;

create or replace function public.admin_add_player(player_name text, player_tier integer, player_th text, player_note text, admin_password text)
returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
 perform public.admin_login_check(admin_password);
 if length(trim(player_name))=0 then raise exception 'Player name required'; end if;
 if player_tier not in (1,2,3) then raise exception 'Tier must be 1, 2, or 3'; end if;
 if (select count(*) from public.players)>=50 then raise exception 'Player limit of 50 reached'; end if;
 insert into public.players(name,tier,th_level,note) values(trim(player_name),player_tier,coalesce(player_th,''),coalesce(player_note,'')) returning id into new_id;
 insert into public.auction_events(type,message,player_id) values('PLAYER ADDED',trim(player_name)||' added to Tier '||player_tier,new_id);
 return new_id;
end $$;

create or replace function public.admin_update_captain(captain_uuid uuid, captain_name text, captain_budget integer, admin_password text)
returns boolean language plpgsql security definer set search_path=public as $$
begin
 perform public.admin_login_check(admin_password);
 if captain_budget<0 or length(trim(captain_name))=0 then raise exception 'Enter a captain name and non-negative purse'; end if;
 update public.captains set name=trim(captain_name),budget=captain_budget where id=captain_uuid;
 if not found then raise exception 'Captain not found'; end if;
 insert into public.auction_events(type,message,captain_id) values('ADMIN',trim(captain_name)||' team purse set to '||captain_budget,captain_uuid);
 return true;
end $$;

grant usage on schema public to anon, authenticated;
grant select on public.captains,public.players,public.auction_events,public.auction_settings to anon,authenticated;
grant execute on function public.admin_login_check(text) to anon,authenticated;
grant execute on function public.admin_select_player(uuid,text) to anon,authenticated;
grant execute on function public.place_auction_bid(uuid,uuid,integer) to anon,authenticated;
grant execute on function public.admin_close_player(uuid,text,text) to anon,authenticated;
grant execute on function public.admin_add_player(text,integer,text,text,text) to anon,authenticated;
grant execute on function public.admin_update_captain(uuid,text,integer,text) to anon,authenticated;

-- Enable Realtime for the tables watched by the site.
do $$ begin
 alter publication supabase_realtime add table public.players;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
 alter publication supabase_realtime add table public.captains;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
 alter publication supabase_realtime add table public.auction_events;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
 alter publication supabase_realtime add table public.auction_settings;
exception when duplicate_object then null; when undefined_object then null; end $$;
