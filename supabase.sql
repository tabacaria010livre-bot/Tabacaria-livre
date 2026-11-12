-- ============================================================
-- Comanda: banco compartilhado + aprovação de cadastros + admins
-- Cole TUDO no SQL Editor do Supabase e execute. Pode rodar de novo sem problema.
-- ============================================================

-- 1) Perfis (quem pode entrar e quem é administrador)
create table if not exists public.perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  status text not null default 'pendente' check (status in ('pendente','aprovado','recusado')),
  is_admin boolean not null default false,
  criado_em timestamptz not null default now()
);
alter table public.perfis enable row level security;

-- 2) Funções de apoio
create or replace function public.is_aprovado()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and status = 'aprovado');
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and status = 'aprovado' and is_admin);
$$;

-- 3) Quem já tem conta hoje entra como aprovado; a conta mais antiga vira administradora
insert into public.perfis (id, email, status, is_admin)
select u.id, u.email, 'aprovado', (row_number() over (order by u.created_at) = 1)
from auth.users u
where not exists (select 1 from public.perfis);

-- 4) Novos cadastros: o primeiro de todos vira admin; os demais ficam pendentes
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare primeiro boolean;
begin
  select not exists (select 1 from public.perfis) into primeiro;
  insert into public.perfis (id, email, status, is_admin)
  values (new.id, new.email, case when primeiro then 'aprovado' else 'pendente' end, primeiro)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 5) Ações do administrador (só admins conseguem executar)
create or replace function public.admin_status(alvo uuid, novo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores podem fazer isso.'; end if;
  if novo not in ('pendente','aprovado','recusado') then raise exception 'Status inválido.'; end if;
  if alvo = auth.uid() and novo <> 'aprovado' then raise exception 'Você não pode bloquear a si mesmo.'; end if;
  if novo <> 'aprovado'
     and exists (select 1 from public.perfis where id = alvo and is_admin and status = 'aprovado')
     and (select count(*) from public.perfis where is_admin and status = 'aprovado') <= 1 then
    raise exception 'Não é possível bloquear o último administrador.';
  end if;
  update public.perfis set status = novo where id = alvo;
end $$;

create or replace function public.admin_papel(alvo uuid, valor boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores podem fazer isso.'; end if;
  if valor and not exists (select 1 from public.perfis where id = alvo and status = 'aprovado') then
    raise exception 'Aprove o cadastro antes de torná-lo administrador.';
  end if;
  if not valor
     and exists (select 1 from public.perfis where id = alvo and is_admin and status = 'aprovado')
     and (select count(*) from public.perfis where is_admin and status = 'aprovado') <= 1 then
    raise exception 'Mantenha pelo menos um administrador.';
  end if;
  update public.perfis set is_admin = valor where id = alvo;
end $$;

revoke all on function public.admin_status(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_papel(uuid, boolean) from public, anon, authenticated;
grant execute on function public.admin_status(uuid, text) to authenticated;
grant execute on function public.admin_papel(uuid, boolean) to authenticated;

-- 6) Regras de acesso aos perfis (só leitura; alterações só pelas funções acima)
drop policy if exists "perfis_select" on public.perfis;
create policy "perfis_select" on public.perfis
  for select to authenticated using (id = auth.uid() or public.is_admin());

-- 7) Dados da comanda: agora são compartilhados por todos os usuários aprovados
create table if not exists public.registros (
  user_id uuid default auth.uid(),
  tipo text not null,
  id text not null,
  dados jsonb not null default '{}'::jsonb,
  apagado boolean not null default false,
  atualizado_em timestamptz not null default now(),
  primary key (tipo, id)
);

alter table public.registros alter column user_id drop not null;
alter table public.registros drop constraint if exists registros_user_id_fkey;
alter table public.registros add constraint registros_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;
alter table public.registros drop constraint if exists registros_pkey;
alter table public.registros add primary key (tipo, id);
create index if not exists registros_atualizado on public.registros (atualizado_em);

alter table public.registros enable row level security;

drop policy if exists "registros_select" on public.registros;
drop policy if exists "registros_insert" on public.registros;
drop policy if exists "registros_update" on public.registros;
drop policy if exists "registros_delete" on public.registros;

create policy "registros_select" on public.registros
  for select to authenticated using (public.is_aprovado());
create policy "registros_insert" on public.registros
  for insert to authenticated with check (public.is_aprovado());
create policy "registros_update" on public.registros
  for update to authenticated using (public.is_aprovado()) with check (public.is_aprovado());
create policy "registros_delete" on public.registros
  for delete to authenticated using (public.is_aprovado());

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
