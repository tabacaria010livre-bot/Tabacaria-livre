-- Cole este arquivo inteiro no SQL Editor do Supabase e execute (pode rodar de novo sem problema).

create table if not exists public.registros (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  tipo text not null,                       -- c = comanda, i = item, g = categoria, s = lancamento de caixa
  id text not null,
  dados jsonb not null default '{}'::jsonb,
  apagado boolean not null default false,
  atualizado_em timestamptz not null default now(),
  primary key (user_id, tipo, id)
);

create index if not exists registros_user_atualizado
  on public.registros (user_id, atualizado_em);

alter table public.registros enable row level security;

drop policy if exists "registros_select" on public.registros;
drop policy if exists "registros_insert" on public.registros;
drop policy if exists "registros_update" on public.registros;
drop policy if exists "registros_delete" on public.registros;

create policy "registros_select" on public.registros
  for select to authenticated using (user_id = auth.uid());
create policy "registros_insert" on public.registros
  for insert to authenticated with check (user_id = auth.uid());
create policy "registros_update" on public.registros
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "registros_delete" on public.registros
  for delete to authenticated using (user_id = auth.uid());

create or replace function public.registros_touch()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  return new;
end $$;

drop trigger if exists registros_touch on public.registros;
create trigger registros_touch
  before insert or update on public.registros
  for each row execute function public.registros_touch();
