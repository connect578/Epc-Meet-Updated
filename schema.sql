-- EPC Meet Kolkata: registrations (production setup)
-- Run once: Supabase > SQL Editor > New query > paste > Run

create table if not exists public.epc_meet_registrations (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  event       text not null default 'kolkata-2026-12-04',
  source      text not null check (source in ('netzero','aerem')),
  full_name   text not null check (char_length(full_name) between 2 and 100),
  phone       text not null check (phone ~ '^[6-9][0-9]{9}$'),
  email       text check (email is null or (char_length(email) <= 150 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
  company     text not null check (char_length(company) between 2 and 150),
  city        text not null check (char_length(city) between 2 and 80),
  ip          text,
  unique (event, phone)
);

create index if not exists epc_meet_registrations_ip_time_idx
  on public.epc_meet_registrations (ip, created_at desc);

-- Clean the data and block floods (max 10 sign-ups per IP in 10 minutes).
create or replace function public.epc_meet_before_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  hdr    json;
  v_ip   text;
  recent int;
begin
  begin
    hdr := current_setting('request.headers', true)::json;
  exception when others then
    hdr := '{}'::json;
  end;

  v_ip := nullif(btrim(split_part(coalesce(hdr->>'cf-connecting-ip', hdr->>'x-forwarded-for', ''), ',', 1)), '');
  new.ip        := v_ip;
  new.full_name := btrim(new.full_name);
  new.company   := btrim(new.company);
  new.city      := btrim(new.city);
  new.email     := nullif(lower(btrim(coalesce(new.email, ''))), '');

  if v_ip is not null then
    select count(*) into recent
    from public.epc_meet_registrations
    where ip = v_ip and created_at > now() - interval '10 minutes';
    if recent >= 10 then
      raise exception 'rate_limited';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists epc_meet_before_insert on public.epc_meet_registrations;
create trigger epc_meet_before_insert
  before insert on public.epc_meet_registrations
  for each row execute function public.epc_meet_before_insert();

-- Lock it down: the public key may only add a registration.
alter table public.epc_meet_registrations enable row level security;

revoke all on public.epc_meet_registrations from anon, authenticated;
grant insert (source, full_name, phone, email, company, city)
  on public.epc_meet_registrations to anon;

drop policy if exists "public can register" on public.epc_meet_registrations;
create policy "public can register"
  on public.epc_meet_registrations
  for insert
  to anon
  with check (true);

-- Team access: open Table Editor > epc_meet_registrations (signed-in members only).
-- Event-day list: Table Editor > Export > CSV.
