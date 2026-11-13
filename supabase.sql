-- =====================================================================
-- Comanda: banco compartilhado + aprovação de cadastros + CARGOS
-- Cargos: desenvolvedor > dono > gerente > funcionário
-- Cole TUDO no SQL Editor do Supabase e execute. Pode rodar de novo sem problema.
-- =====================================================================

-- 1) Perfis
create table if not exists public.perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  status text not null default 'pendente' check (status in ('pendente','aprovado','recusado')),
  cargo text,
  criado_em timestamptz not null default now()
);
alter table public.perfis add column if not exists cargo text;
alter table public.perfis enable row level security;

-- 1b) Migração da versão anterior (is_admin -> cargo)
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'perfis'
      and column_name = 'is_admin' and is_generated = 'NEVER'
  ) then
    execute $q$update public.perfis set cargo = case when is_admin then 'dono' else 'funcionario' end where cargo is null$q$;
    execute 'alter table public.perfis drop column is_admin';
  end if;
end $$;

update public.perfis set cargo = 'funcionario' where cargo is null;
alter table public.perfis alter column cargo set default 'funcionario';
alter table public.perfis alter column cargo set not null;
alter table public.perfis drop constraint if exists perfis_cargo_check;
alter table public.perfis add constraint perfis_cargo_check
  check (cargo in ('desenvolvedor','dono','gerente','funcionario'));

-- is_admin continua existindo (calculado): verdadeiro para desenvolvedor e dono
alter table public.perfis add column if not exists is_admin boolean
  generated always as (cargo in ('desenvolvedor','dono')) stored;

-- 2) Funções de apoio
create or replace function public.rank_cargo(c text)
returns int language sql immutable as $$
  select case c when 'desenvolvedor' then 4 when 'dono' then 3 when 'gerente' then 2 else 1 end;
$$;

create or replace function public.meu_cargo()
returns text language sql stable security definer set search_path = public as $$
  select cargo from public.perfis where id = auth.uid() and status = 'aprovado';
$$;

create or replace function public.is_aprovado()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where id = auth.uid() and status = 'aprovado');
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis
                 where id = auth.uid() and status = 'aprovado' and cargo in ('desenvolvedor','dono'));
$$;

-- 3) Se ainda não há perfis, quem já tem conta entra aprovado (a mais antiga vira dono)
insert into public.perfis (id, email, status, cargo)
select u.id, u.email, 'aprovado',
       case when row_number() over (order by u.created_at) = 1 then 'dono' else 'funcionario' end
from auth.users u
where not exists (select 1 from public.perfis);

-- 4) Novos cadastros: o primeiro de todos vira dono; os demais ficam pendentes (funcionário)
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare primeiro boolean;
begin
  select not exists (select 1 from public.perfis) into primeiro;
  insert into public.perfis (id, email, status, cargo)
  values (new.id, new.email,
          case when primeiro then 'aprovado' else 'pendente' end,
          case when primeiro then 'dono' else 'funcionario' end)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 5) REGRAS (funções puras, sem dados): usadas pelas ações abaixo e pela aba Teste do app
create or replace function public.regra_status(meu text, alvo_cargo text, novo text, mesmo boolean)
returns text language plpgsql immutable as $$
begin
  if meu is null or meu not in ('desenvolvedor','dono','gerente') then
    return 'Você não tem permissão para isso.';
  end if;
  if novo not in ('pendente','aprovado','recusado') then return 'Status inválido.'; end if;
  if mesmo then return 'Você não pode alterar o seu próprio acesso.'; end if;
  if alvo_cargo is null then return 'Usuário não encontrado.'; end if;
  if public.rank_cargo(meu) <= public.rank_cargo(alvo_cargo) then
    return 'Você só pode alterar usuários de cargo abaixo do seu.';
  end if;
  return null;
end $$;

create or replace function public.regra_cargo(meu text, alvo_cargo text, novo_cargo text, status_alvo text, mesmo boolean)
returns text language plpgsql immutable as $$
begin
  if meu is null or meu not in ('desenvolvedor','dono') then
    return 'Apenas o dono ou o desenvolvedor podem alterar cargos.';
  end if;
  if novo_cargo not in ('funcionario','gerente','dono','desenvolvedor') then return 'Cargo inválido.'; end if;
  if mesmo then return 'Você não pode alterar o seu próprio cargo.'; end if;
  if alvo_cargo is null then return 'Usuário não encontrado.'; end if;
  if public.rank_cargo(meu) <= public.rank_cargo(alvo_cargo) then
    return 'Você só pode alterar usuários de cargo abaixo do seu.';
  end if;
  if novo_cargo in ('dono','desenvolvedor') and meu <> 'desenvolvedor' then
    return 'Apenas o desenvolvedor pode criar donos ou outros desenvolvedores.';
  end if;
  if novo_cargo <> 'funcionario' and status_alvo <> 'aprovado' then
    return 'Aprove o cadastro antes de mudar o cargo.';
  end if;
  return null;
end $$;

-- 6) Ações da equipe
--    Aprovar/recusar/bloquear/liberar: gerente, dono e desenvolvedor, só em cargo ABAIXO do seu.
create or replace function public.admin_status(alvo uuid, novo text)
returns void language plpgsql security definer set search_path = public as $$
declare meu text; cargo_alvo text; erro text;
begin
  meu := public.meu_cargo();
  select cargo into cargo_alvo from public.perfis where id = alvo;
  erro := public.regra_status(meu, cargo_alvo, novo, alvo = auth.uid());
  if erro is not null then raise exception '%', erro; end if;
  if novo <> 'aprovado' and cargo_alvo in ('desenvolvedor','dono')
     and (select count(*) from public.perfis
          where status = 'aprovado' and cargo in ('desenvolvedor','dono')) <= 1 then
    raise exception 'Não é possível bloquear o último dono ou desenvolvedor.';
  end if;
  update public.perfis set status = novo where id = alvo;
end $$;

--    Mudar cargo: só dono e desenvolvedor. Gerente NÃO promove ninguém.
--    Dono promove/rebaixa até gerente. Só o desenvolvedor cria donos.
--    O cargo desenvolvedor é protegido: ninguém o altera pelo app.
create or replace function public.admin_cargo(alvo uuid, novo_cargo text)
returns void language plpgsql security definer set search_path = public as $$
declare meu text; cargo_alvo text; status_alvo text; erro text;
begin
  meu := public.meu_cargo();
  select cargo, status into cargo_alvo, status_alvo from public.perfis where id = alvo;
  erro := public.regra_cargo(meu, cargo_alvo, novo_cargo, status_alvo, alvo = auth.uid());
  if erro is not null then raise exception '%', erro; end if;
  update public.perfis set cargo = novo_cargo where id = alvo;
end $$;

drop function if exists public.admin_papel(uuid, boolean);

revoke all on function public.admin_status(uuid, text) from public, anon, authenticated;
revoke all on function public.admin_cargo(uuid, text) from public, anon, authenticated;
revoke all on function public.regra_status(text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.regra_cargo(text, text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.admin_status(uuid, text) to authenticated;
grant execute on function public.admin_cargo(uuid, text) to authenticated;
grant execute on function public.regra_status(text, text, text, boolean) to authenticated;
grant execute on function public.regra_cargo(text, text, text, text, boolean) to authenticated;

-- 7) Regras de acesso aos perfis (somente leitura pela API; mudanças só pelas funções acima)
drop policy if exists "perfis_select" on public.perfis;
create policy "perfis_select" on public.perfis
  for select to authenticated
  using (id = auth.uid() or public.meu_cargo() in ('desenvolvedor','dono','gerente'));

-- 8) Dados da comanda: compartilhados por todos os usuários aprovados
create table if not exists public.registros (
  user_id uuid default auth.uid(),
  tipo text not null,
  id text not null,
  dados jsonb not null default '{}'::jsonb,
  apagado boolean not null default false,
  atualizado_em timestamptz not null default now(),
  primary key (tipo, id)
);

alter table public.registros drop constraint if exists registros_pkey;
alter table public.registros alter column user_id drop not null;
alter table public.registros drop constraint if exists registros_user_id_fkey;
alter table public.registros add constraint registros_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;
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

-- 9) CARGO DE DESENVOLVEDOR (protegido): definido SÓ por aqui, nunca pelo app.
--    Troque o e-mail se for outra conta e execute novamente.
update public.perfis
set cargo = 'desenvolvedor', status = 'aprovado'
where lower(email) = lower('games010brasil@gmail.com');
