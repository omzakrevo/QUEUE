-- OMZA QUEUE - schéma PostgreSQL (idempotent)
create table if not exists organizations (
  id serial primary key,
  name text not null,
  logo text,
  address text,
  phone text,
  created_at timestamptz not null default now()
);

create table if not exists users (
  id serial primary key,
  name text not null,
  username text not null unique,
  password_hash text not null,
  role text not null check (role in ('administrateur','superviseur','agent','responsable','borne','affichage')),
  status text not null default 'active' check (status in ('active','disabled')),
  created_at timestamptz not null default now()
);

create table if not exists services (
  id serial primary key,
  organization_id int references organizations(id) on delete set null,
  name text not null,
  code varchar(4) not null unique,
  description text,
  color text not null default '#1e88e5',
  priority int not null default 0,          -- ordre de priorité du service (plus grand = servi d'abord)
  open_time time,                            -- horaires d'ouverture (null = toujours ouvert)
  close_time time,
  active boolean not null default true
);

create table if not exists counters (
  id serial primary key,
  name text not null,
  number int not null unique,
  status text not null default 'closed' check (status in ('open','paused','closed'))
);

create table if not exists counter_services (
  counter_id int not null references counters(id) on delete cascade,
  service_id int not null references services(id) on delete cascade,
  primary key (counter_id, service_id)
);

create table if not exists agents (
  id serial primary key,
  user_id int not null unique references users(id) on delete cascade,
  counter_id int references counters(id) on delete set null,
  service_id int references services(id) on delete set null
);

create table if not exists terminals (
  id serial primary key,
  name text not null,
  device_type text not null default 'windows' check (device_type in ('windows','android','web')),
  printer_type text not null default 'none' check (printer_type in ('none','usb','network')),
  printer_address text,                      -- hôte:port pour imprimante réseau (ex. 192.168.1.50:9100)
  paper_width int not null default 80 check (paper_width in (58,80)),
  status text not null default 'active',
  last_seen timestamptz
);

-- Compteurs de numérotation : une ligne par (service, périmètre). Le verrou de ligne
-- pris par l'UPSERT sérialise les bornes concurrentes.
create table if not exists ticket_counters (
  service_id int not null references services(id) on delete cascade,
  scope_key text not null,
  last_number int not null default 0,
  primary key (service_id, scope_key)
);

create table if not exists tickets (
  id bigserial primary key,
  ticket_number text not null,
  origin_service_id int not null references services(id),
  scope_key text not null,
  seq int not null,
  service_id int not null references services(id),   -- service courant (change en cas de transfert)
  counter_id int references counters(id) on delete set null,
  terminal_id int references terminals(id) on delete set null,
  status text not null default 'waiting'
    check (status in ('waiting','called','serving','done','absent','cancelled')),
  priority int not null default 0,
  access_token text not null unique,                 -- jeton aléatoire du QR Code (aucune donnée personnelle)
  reprint_count int not null default 0,
  created_at timestamptz not null default now(),
  queue_at timestamptz not null default now(),       -- position dans la file (remis à now() après ignore/transfert)
  called_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  unique (origin_service_id, scope_key, seq)
);
create index if not exists tickets_queue_idx on tickets (service_id, status, priority desc, queue_at, id);
create index if not exists tickets_created_idx on tickets (created_at);
create index if not exists tickets_counter_idx on tickets (counter_id, status);

create table if not exists ticket_events (
  id bigserial primary key,
  ticket_id bigint not null references tickets(id) on delete cascade,
  event_type text not null,
  user_id int references users(id) on delete set null,
  created_at timestamptz not null default now(),
  details jsonb
);
create index if not exists ticket_events_ticket_idx on ticket_events (ticket_id, created_at);

create table if not exists settings (
  id serial primary key,
  setting_key text not null unique,
  setting_value text
);

create table if not exists audit_logs (
  id bigserial primary key,
  user_id int references users(id) on delete set null,
  action text not null,
  created_at timestamptz not null default now(),
  details jsonb
);
create index if not exists audit_created_idx on audit_logs (created_at desc);
