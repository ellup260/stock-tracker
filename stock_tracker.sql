-- Stock tracker: schema, access rules and sample data (Supabase / Postgres)
-- Run in the Supabase SQL editor.

-- 1. TABLES ---------------------------------------------------------------

create table items (
  id          uuid primary key default gen_random_uuid(),
  sku         text not null unique,
  name        text not null,
  unit        text not null default 'each',
  created_at  timestamptz not null default now()
);

create table locations (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,          -- e.g. 'A-01-02'
  name        text not null,
  created_at  timestamptz not null default now()
);

-- Who can do what. One row per signed-in user.
create table profiles (
  id    uuid primary key references auth.users (id) on delete cascade,
  role  text not null default 'picker' check (role in ('picker', 'supervisor'))
);

-- Every change to stock is a row here. Rows are never edited or deleted.
-- Positive quantity = stock in, negative = stock out.
create table stock_movements (
  id             bigint generated always as identity primary key,
  item_id        uuid not null references items (id),
  location_id    uuid not null references locations (id),
  quantity       integer not null check (quantity <> 0),
  movement_type  text not null
                 check (movement_type in ('receive', 'pick', 'adjust', 'transfer_in', 'transfer_out')),
  note           text,
  created_by     uuid default auth.uid() references auth.users (id),
  created_at     timestamptz not null default now()
);

create index on stock_movements (item_id, location_id);

-- 2. STOCK LEVELS (calculated, never typed in) ---------------------------

create view stock_levels
with (security_invoker = true) as
select
  m.item_id,
  i.sku,
  i.name       as item_name,
  m.location_id,
  l.code       as location_code,
  sum(m.quantity)::integer as on_hand
from stock_movements m
join items i     on i.id = m.item_id
join locations l on l.id = m.location_id
group by m.item_id, i.sku, i.name, m.location_id, l.code;

-- 3. ACCESS RULES ---------------------------------------------------------

alter table items            enable row level security;
alter table locations        enable row level security;
alter table profiles         enable row level security;
alter table stock_movements  enable row level security;

create function is_supervisor() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles where id = auth.uid() and role = 'supervisor'
  );
$$;

-- Everyone signed in can read.
create policy "read items"     on items           for select to authenticated using (true);
create policy "read locations" on locations       for select to authenticated using (true);
create policy "read movements" on stock_movements for select to authenticated using (true);
create policy "read own profile" on profiles      for select to authenticated using (id = auth.uid());

-- Pickers can record movements as themselves, but only supervisors can record adjustments.
create policy "record movements" on stock_movements
  for insert to authenticated
  with check (
    created_by = auth.uid()
    and (movement_type <> 'adjust' or is_supervisor())
  );

-- Only supervisors manage items and locations.
create policy "supervisors manage items" on items
  for all to authenticated using (is_supervisor()) with check (is_supervisor());
create policy "supervisors manage locations" on locations
  for all to authenticated using (is_supervisor()) with check (is_supervisor());

-- No update or delete policies exist on stock_movements, so history is read-only.
-- Belt and braces: remove the privileges and block it with a trigger too.
revoke update, delete on stock_movements from anon, authenticated;

create function block_movement_changes() returns trigger
language plpgsql as $$
begin
  raise exception 'Stock movements are append-only. Record a reversing movement instead.';
end;
$$;

create trigger movements_append_only
  before update or delete on stock_movements
  for each row execute function block_movement_changes();

-- 4. SAMPLE DATA ----------------------------------------------------------

insert into items (sku, name, unit) values
  ('BLT-M8-50',  'M8 bolts (box of 50)',    'box'),
  ('GLV-L-12',   'Work gloves, large',      'pair'),
  ('TAP-48-CLR', 'Packing tape 48mm, clear', 'roll'),
  ('LBL-4X6',    'Shipping labels 4x6',     'roll');

insert into locations (code, name) values
  ('A-01-01', 'Aisle A, bay 1, shelf 1'),
  ('A-01-02', 'Aisle A, bay 1, shelf 2'),
  ('B-02-01', 'Aisle B, bay 2, shelf 1');

insert into stock_movements (item_id, location_id, quantity, movement_type, note)
select i.id, l.id, v.qty, v.mtype, v.note
from (values
  ('BLT-M8-50',  'A-01-01', 200, 'receive',      'Initial delivery'),
  ('BLT-M8-50',  'A-01-01', -35, 'pick',         'Order 1001'),
  ('BLT-M8-50',  'A-01-01', -20, 'pick',         'Order 1004'),
  ('GLV-L-12',   'A-01-02',  60, 'receive',      'Initial delivery'),
  ('GLV-L-12',   'A-01-02', -12, 'pick',         'Order 1002'),
  ('GLV-L-12',   'A-01-02',  -2, 'adjust',       'Damaged pairs written off'),
  ('TAP-48-CLR', 'B-02-01', 144, 'receive',      'Initial delivery'),
  ('TAP-48-CLR', 'B-02-01', -24, 'transfer_out', 'Moved to packing bench'),
  ('LBL-4X6',    'B-02-01',  40, 'receive',      'Initial delivery'),
  ('LBL-4X6',    'B-02-01',  -6, 'pick',         'Order 1003')
) as v(sku, loc, qty, mtype, note)
join items i     on i.sku = v.sku
join locations l on l.code = v.loc;

-- 5. CHECK IT WORKS -------------------------------------------------------
-- select * from stock_levels order by sku;
-- Expected on_hand: BLT-M8-50 = 145, GLV-L-12 = 46, TAP-48-CLR = 120, LBL-4X6 = 34
