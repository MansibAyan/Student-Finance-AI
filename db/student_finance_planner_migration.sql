-- Additive migration for competition upgrade: savings goals + planner RPC.
-- Run in Supabase SQL Editor only after confirming public.app_handle(uuid, jsonb) exists.
-- This does not replace your existing finance functions or tables.

begin;

create table if not exists public.student_savings_goals (
  goal_id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  goal_name text not null check (length(trim(goal_name)) between 1 and 80),
  target_amount numeric(14,2) not null check (target_amount > 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  deadline_date date not null,
  status text not null default 'active' check (status in ('active','completed','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists student_savings_goals_user_status_idx
  on public.student_savings_goals(user_id, status, deadline_date);

alter table public.student_savings_goals enable row level security;
revoke all on table public.student_savings_goals from public, anon, authenticated;
grant select, insert, update, delete on table public.student_savings_goals to service_role;

create or replace function public.student_planner_handle(p_user uuid, p_action jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_action text := coalesce(p_action->>'action','');
  v_goal_id uuid;
  v_name text;
  v_amount numeric(14,2);
  v_currency text;
  v_deadline date;
  v_goals jsonb;
  v_snapshot_result jsonb;
  v_snapshot jsonb;
  v_budget jsonb;
  v_balances jsonb;
  v_spent numeric := 0;
  v_monthly_budget numeric;
  v_projected numeric := 0;
  v_remaining numeric;
  v_elapsed integer;
  v_days_remaining integer;
  v_currency_code text;
  v_whatif_amount numeric;
  v_balance numeric;
  v_item text;
  v_tips jsonb := '[]'::jsonb;
begin
  if p_user is null then
    return jsonb_build_object('ok',false,'error','missing_user');
  end if;
  if p_action is null or jsonb_typeof(p_action) <> 'object' then
    return jsonb_build_object('ok',false,'error','invalid_action');
  end if;

  if v_action = 'planner_goal_set' then
    v_name := left(trim(coalesce(p_action->>'goal_name','')),80);
    v_amount := nullif(p_action->>'target_amount','')::numeric;
    v_currency := upper(coalesce(p_action->>'currency',''));
    v_deadline := nullif(p_action->>'deadline_date','')::date;
    if v_name = '' or v_amount is null or v_amount <= 0 or v_currency !~ '^[A-Z]{3}$' or v_deadline is null or v_deadline <= current_date then
      return jsonb_build_object('ok',false,'error','invalid_goal_fields');
    end if;
    insert into public.student_savings_goals(user_id,goal_name,target_amount,currency,deadline_date)
    values(p_user,v_name,v_amount,v_currency,v_deadline)
    returning goal_id into v_goal_id;
    return jsonb_build_object('ok',true,'message',format('Savings goal created: %s — %s %s by %s.',v_name,v_amount,v_currency,v_deadline),'goal_id',v_goal_id);

  elsif v_action = 'planner_goal_list' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'goal_id',g.goal_id,'goal_name',g.goal_name,'target_amount',g.target_amount,
      'currency',g.currency,'deadline_date',g.deadline_date,'status',g.status,
      'days_left',greatest(0,g.deadline_date-current_date),
      'daily_save_needed',round(g.target_amount / greatest(1,g.deadline_date-current_date),2)
    ) order by g.deadline_date),'[]'::jsonb)
    into v_goals
    from public.student_savings_goals g
    where g.user_id=p_user and g.status='active';
    return jsonb_build_object('ok',true,'goals',v_goals);

  elsif v_action = 'planner_goal_delete' then
    begin v_goal_id := (p_action->>'goal_id')::uuid;
    exception when others then return jsonb_build_object('ok',false,'error','invalid_goal_id'); end;
    delete from public.student_savings_goals where goal_id=v_goal_id and user_id=p_user;
    if not found then return jsonb_build_object('ok',false,'error','goal_not_found'); end if;
    return jsonb_build_object('ok',true,'message','Savings goal deleted.');

  elsif v_action in ('planner_forecast','planner_coach','planner_what_if') then
    -- Reuse the existing trusted ledger snapshot rather than reading assumed table names.
    v_snapshot_result := public.app_handle(p_user, jsonb_build_object('action','snapshot'));
    v_snapshot := coalesce(v_snapshot_result->'snapshot','{}'::jsonb);
    v_budget := coalesce(v_snapshot->'budget','{}'::jsonb);
    v_balances := coalesce(v_snapshot->'balances','{}'::jsonb);
    begin v_spent := greatest(0,coalesce(nullif(v_budget->>'month_spent','')::numeric,0)); exception when others then v_spent:=0; end;
    begin v_monthly_budget := nullif(v_budget->>'monthly_budget','')::numeric; exception when others then v_monthly_budget:=null; end;
    v_currency_code := upper(coalesce(v_budget->>'currency','BDT'));
    v_elapsed := greatest(1,extract(day from current_date)::integer);
    v_days_remaining := greatest(0,((date_trunc('month',current_date)+interval '1 month')::date-current_date)-1);
    v_projected := round((v_spent / v_elapsed) * (v_elapsed + v_days_remaining),2);
    v_remaining := case when v_monthly_budget is null then null else round(v_monthly_budget-v_projected,2) end;

    if v_action='planner_forecast' then
      return jsonb_build_object('ok',true,'forecast',jsonb_build_object(
        'month_spent',v_spent,'projected_month_spend',v_projected,'monthly_budget',v_monthly_budget,
        'projected_remaining',v_remaining,'currency',v_currency_code,'days_elapsed',v_elapsed,
        'days_remaining',v_days_remaining));

    elsif v_action='planner_coach' then
      if coalesce((v_budget->>'review_required')::boolean,false) then
        v_tips := v_tips || jsonb_build_array('Your recorded spending has triggered a budget review. Check recent categories and adjust non-essential plans; do not skip essentials such as food, medicine or transport.');
      elsif coalesce((v_budget->>'overspend')::numeric,0)>0 then
        v_tips := v_tips || jsonb_build_array('Today is above the recorded daily allowance. Review flexible purchases and check whether essential costs need a realistic budget adjustment.');
      else
        v_tips := v_tips || jsonb_build_array('Keep recording expenses consistently so the budget guidance and forecast become more reliable.');
      end if;
      if v_monthly_budget is not null and v_projected>v_monthly_budget then
        v_tips := v_tips || jsonb_build_array('At the current month-to-date pace, spending may exceed the monthly budget. Compare upcoming bills with flexible spending before making new commitments.');
      end if;
      if exists(select 1 from public.student_savings_goals where user_id=p_user and status='active') then
        v_tips := v_tips || jsonb_build_array('Review your active savings goals before discretionary purchases; the goal list shows the daily saving pace required.');
      else
        v_tips := v_tips || jsonb_build_array('If you are saving for tuition or a device, create a goal with /goal set Name | amount | BDT | YYYY-MM-DD.');
      end if;
      return jsonb_build_object('ok',true,'coach',v_tips);

    else
      v_whatif_amount := nullif(p_action->>'amount','')::numeric;
      v_currency_code := upper(coalesce(p_action->>'currency',''));
      v_item := left(trim(coalesce(p_action->>'item','purchase')),80);
      if v_whatif_amount is null or v_whatif_amount<=0 or v_whatif_amount>10000000 or v_currency_code !~ '^[A-Z]{3}$' then
        return jsonb_build_object('ok',false,'error','invalid_what_if_fields');
      end if;
      begin v_balance := nullif(v_balances->>v_currency_code,'')::numeric; exception when others then v_balance:=null; end;
      if v_balance is null then
        return jsonb_build_object('ok',true,'what_if',jsonb_build_object('item',v_item,'amount',v_whatif_amount,'currency',v_currency_code,'recorded_balance',null,'assessment','No recorded balance in this currency, so affordability cannot be assessed reliably. Add accurate records or use your actual available funds to decide.'));
      elsif v_whatif_amount>v_balance then
        return jsonb_build_object('ok',true,'what_if',jsonb_build_object('item',v_item,'amount',v_whatif_amount,'currency',v_currency_code,'recorded_balance',v_balance,'assessment','This purchase is higher than the recorded ledger balance in this currency. The ledger may be incomplete; do not treat this as a bank balance.'));
      else
        return jsonb_build_object('ok',true,'what_if',jsonb_build_object('item',v_item,'amount',v_whatif_amount,'currency',v_currency_code,'recorded_balance',v_balance,'assessment',format('After this hypothetical purchase, the recorded ledger balance would be %s %s before other bills. Check tuition, debt payments and essential costs first.',round(v_balance-v_whatif_amount,2),v_currency_code)));
      end if;
    end if;
  end if;
  return jsonb_build_object('ok',false,'error','unsupported_planner_action');
exception when others then
  return jsonb_build_object('ok',false,'error','planner_operation_failed');
end;
$$;

revoke all on function public.student_planner_handle(uuid,jsonb) from public, anon, authenticated;
grant execute on function public.student_planner_handle(uuid,jsonb) to service_role;

commit;
