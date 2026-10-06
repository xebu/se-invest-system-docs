#!/usr/bin/env bash
#
# Reproduces the RLS-bypass-through-views finding against the repo's own
# exported schema. Read-only with respect to the repo: it copies
# backend/sql/export/schema.sql into a throwaway container and never writes
# back. Verified on 2026-10-06 against commit 58fbc761, PostgreSQL 16.15.
#
# Usage:  REPO=/path/to/InvestmentSystem ./2026-10-06-rls-view-bypass.sh
#
set -euo pipefail
REPO="${REPO:-$HOME/code/work/sportsengland/sportsengland/InvestmentSystem}"
SCHEMA="$REPO/backend/sql/export/schema.sql"
CTR=rlstest
TA=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
TB=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

[ -f "$SCHEMA" ] || { echo "schema not found: $SCHEMA"; exit 1; }

docker rm -f $CTR >/dev/null 2>&1 || true
docker run -d --name $CTR -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:16 >/dev/null
until docker exec $CTR pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done

# Role topology exactly as backend/sql/pgutil creates it.
# NB: admin is NOT a superuser upstream (SUPERUSER is commented out at pgutil:107),
#     which matters: a superuser would bypass RLS for an unrelated reason.
docker exec -i $CTR psql -U postgres -v ON_ERROR_STOP=1 -q <<SQL
CREATE ROLE admin WITH CREATEROLE LOGIN ENCRYPTED PASSWORD 'admin';
CREATE ROLE readonly_access  WITH PASSWORD 'ro';
CREATE ROLE readwrite_access WITH PASSWORD 'rw';
GRANT readonly_access  TO admin;
GRANT readwrite_access TO admin;
CREATE USER queryuser  WITH INHERIT LOGIN ENCRYPTED PASSWORD 'q';  -- POSTGRES_QUERY_URI  (the BFF)
GRANT readonly_access  TO queryuser;
CREATE USER mutateuser WITH INHERIT LOGIN ENCRYPTED PASSWORD 'm';  -- POSTGRES_MUTATE_URI (the API)
GRANT readwrite_access TO mutateuser;
CREATE DATABASE arena OWNER admin;
SQL
docker exec -i $CTR psql -U postgres -d arena -q -c 'ALTER SCHEMA public OWNER TO admin;' -c 'GRANT CREATE ON DATABASE arena TO admin;'

# psql 16 does not know \restrict / \unrestrict (psql 18 meta-commands)
grep -vE '^\\(restrict|unrestrict)' "$SCHEMA" | docker exec -i $CTR tee /tmp/schema.sql >/dev/null
docker exec -i $CTR psql -U admin -d arena -v ON_ERROR_STOP=1 -q -f /tmp/schema.sql

docker exec -i $CTR psql -U admin -d arena -v ON_ERROR_STOP=1 -q <<'SQL'
GRANT USAGE ON SCHEMA public TO readonly_access;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_access;
GRANT USAGE ON SCHEMA public TO readwrite_access;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO readwrite_access;
SQL

echo "== premises =="
docker exec -i $CTR psql -U admin -d arena -tA -c "
select 'views=' ||(select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='v')
    ||' security_invoker=' ||(select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='v' and c.reloptions::text like '%security_invoker%')
    ||' force_rls=' ||(select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relforcerowsecurity)
    ||' owners=' ||(select string_agg(distinct pg_get_userbyid(relowner),',') from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and relkind in ('r','v'));"

# Two tenants through project_payment_schedule's full join chain.
docker exec -i $CTR psql -U admin -d arena -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$
DECLARE t uuid; ba uuid; org uuid; app uuid; proj uuid; pay uuid; bliy uuid; bli uuid;
  prog uuid := uuid_generate_v4(); pep uuid := uuid_generate_v4();
  frp uuid := uuid_generate_v4(); fnd uuid := uuid_generate_v4();
BEGIN
  FOREACH t IN ARRAY ARRAY['$TA'::uuid,'$TB'::uuid] LOOP
    ba:=uuid_generate_v4(); org:=uuid_generate_v4(); app:=uuid_generate_v4();
    proj:=uuid_generate_v4(); pay:=uuid_generate_v4(); bliy:=uuid_generate_v4(); bli:=uuid_generate_v4();
    INSERT INTO tenants (tenant_id,display_name,slug,domain,tenant_key,tenant_secret)
      VALUES (t,'Tenant '||left(t::text,1),left(t::text,1),left(t::text,1)||'.example.org','k-'||t,'s-'||t);
    INSERT INTO bank_accounts (tenant_id,owner_id,id,name,status,bank_account_name,bank_details_are_valid,bank_details_checked_at)
      VALUES (t,t,ba,'acct','ok','Acct '||left(t::text,1),true,now());
    INSERT INTO organisation (tenant_id,owner_id,id,name,status,organisation_reference,bank_account_id)
      VALUES (t,t,org,'Org '||left(t::text,1),'active','REF-'||left(t::text,1),ba);
    INSERT INTO application (tenant_id,owner_id,id,name,status,applicant_id,organisation_id,programme_id,application_summary)
      VALUES (t,t,app,'App '||left(t::text,1),'approved',uuid_generate_v4(),org,prog,'Summary for tenant '||left(t::text,1));
    INSERT INTO project (tenant_id,owner_id,id,name,status,application_id,organisation_id,programme_id,funding_type,funding_total_minor)
      VALUES (t,t,proj,'Proj '||left(t::text,1),'live',app,org,prog,'grant',5000000);
    INSERT INTO project_payments (tenant_id,owner_id,id,name,status,project_id,due_date,expires_date,payment_type,payment_filter,is_payable,reference)
      VALUES (t,t,pay,'Pay '||left(t::text,1),'approved',proj,current_date,current_date+30,'grant','standard',true,'PAYREF-'||left(t::text,1));
    INSERT INTO budget_line_item_project_year (tenant_id,owner_id,id,name,status,budget_line_item_id,project_year,due_date,expires_date,
           amount_minor,fund_revenue_period_id,programme_expense_period_id,fund_id,fund_name,fund_period_start,fund_period_end,
           programme_id,programme_period_start,programme_period_end,expenditure,commitment)
      VALUES (t,t,bliy,'bliy','ok',bli,1,current_date,current_date+30,1000000,frp,pep,fnd,'Fund '||left(t::text,1),
              current_date-365,current_date+365,prog,current_date-365,current_date+365,'capital','committed');
    INSERT INTO project_payment_line_items (tenant_id,owner_id,id,name,status,project_payment_id,line_item_id,line_item_year_id,
           project_year,expenditure,description,category,programme_id,programme_expense_period_id,fund_revenue_period_id,fund_id,fund_name,amount_minor)
      VALUES (t,t,uuid_generate_v4(),'li','ok',pay,bli,bliy,1,'capital','Line item for '||left(t::text,1),'build',
              prog,pep,frp,fnd,'Fund '||left(t::text,1),1000000);
  END LOOP;
END \$\$;
SQL

for U in queryuser mutateuser; do
  echo "== BEFORE FIX, as \$U scoped to tenant A =="
  docker exec -i $CTR psql -U $U -d arena -tA <<SQL
select set_config('rls.tenant','$TA',false); select set_config('rls.owner','$TA',false);
select '  application table  = '||count(*) from application;
select '  view               = '||count(*) from project_payment_schedule;
select '  LEAKED: '||organisation_name||' / '||reference from project_payment_schedule where status='approved';
SQL
done

echo "== applying fix: security_invoker on all views (incl. the 3 nested ones) =="
docker exec -i $CTR psql -U admin -d arena -q -c "
do \$\$ declare v record; begin
  for v in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='v' and n.nspname='public'
  loop execute format('ALTER VIEW public.%I SET (security_invoker = true)', v.relname); end loop; end \$\$;"

for U in queryuser mutateuser; do
  echo "== AFTER FIX, as \$U scoped to tenant A =="
  docker exec -i $CTR psql -U $U -d arena -tA <<SQL
select set_config('rls.tenant','$TA',false); select set_config('rls.owner','$TA',false);
select '  view = '||count(*)||'  ('||coalesce(string_agg(organisation_name,','),'-')||')' from project_payment_schedule;
SQL
done
echo "== owner (migrations/pg_dump) unaffected by the fix =="
docker exec -i $CTR psql -U admin -d arena -tAc "select '  admin reads application = '||count(*) from application;"

echo
echo "Teardown: docker rm -f $CTR"
