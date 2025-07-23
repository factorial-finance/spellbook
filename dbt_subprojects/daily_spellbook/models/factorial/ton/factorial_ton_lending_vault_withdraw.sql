{{ config(
       schema = 'factorial_ton'
       , alias = 'lending_vault_withdraw'
       , materialized = 'incremental'
       , file_format = 'delta'
       , incremental_strategy = 'merge'
       , incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.block_date')]
       , unique_key = ['tx_hash', 'block_date']
       , post_hook='{{ expose_spells(\'["ton"]\',
                                   "project",
                                   "factorial",
                                   \'["seth"]\') }}'
   )
 }}

-- based on reference implementation: https://github.com/factorial-finance/action-notification-parser/blob/main/src/index.ts

WITH factorial_ton_lending_vaults AS (
    {{ factorial_ton_lending_vaults() }}
),
all_messages AS (
    SELECT 
        M.block_date, 
        M.tx_hash, 
        M.trace_id, 
        M.tx_now, 
        M.tx_lt, 
        M.destination,
        M.source,
        M.opcode, 
        M.body_boc,
        M.direction,
        v.vault_address,
        v.vault_name,
        CASE 
            WHEN M.direction = 'in' AND M.opcode = 2078119902 THEN 'burn_notification'
            WHEN M.direction = 'out' AND M.opcode = 395134233 THEN 'mint'
            WHEN M.direction = 'in' AND M.opcode = -1582162293 THEN 'action_notification'
            WHEN M.direction = 'out' AND M.opcode = 260734629 THEN 'transfer'
        END AS message_type
    FROM {{ source('ton', 'messages') }} M
    JOIN factorial_ton_lending_vaults v
        ON (M.direction = 'in' AND M.opcode = 2078119902 AND M.destination = v.vault_address)
        OR (M.direction = 'out' AND M.opcode = 395134233 AND M.source = v.vault_address)
        OR (M.direction = 'in' AND M.opcode = -1582162293 AND M.destination = v.vault_address)
        OR (M.direction = 'out' AND M.opcode = 260734629 AND M.source = v.vault_address)
    WHERE M.block_date >= TIMESTAMP '2025-07-01'
    {% if is_incremental() %}
        AND {{ incremental_predicate('M.block_date') }}
    {% endif %}
),
joined_messages AS (
    SELECT 
        n.block_date,
        n.tx_hash,
        n.trace_id,
        n.tx_now,
        n.tx_lt,
        n.vault_address,
        n.vault_name,
        n.body_boc AS notification_boc,
        m.body_boc AS mint_boc
    FROM all_messages n
    LEFT JOIN all_messages m 
        ON n.trace_id = m.trace_id 
        AND n.vault_address = m.vault_address  -- 같은 vault
        AND n.message_type = 'burn_notification' 
        AND m.message_type = 'mint'
    WHERE n.message_type = 'burn_notification'
),
parsed_results AS (
    SELECT 
        block_date,
        tx_hash,
        trace_id,
        tx_now,
        tx_lt,
        vault_address,
        vault_name,
        {{ ton_from_boc('notification_boc', [
            ton_begin_parse(),
            ton_skip_bits(32),
            ton_load_uint(64, 'query_id'),
            ton_load_coins('burn_amount'),
            ton_load_address('owner_address')
        ]) }} AS notification_result,
        CASE 
            WHEN mint_boc IS NOT NULL THEN
                {{ ton_from_boc('mint_boc', [
                    ton_begin_parse(),
                    ton_skip_bits(32),
                    ton_load_uint(64, 'query_id'),
                    ton_load_coins('mint_amount')
                ]) }}
            ELSE NULL
        END AS mint_result
    FROM joined_messages
),
burn_results AS (
    SELECT 
        block_date,
        tx_hash,
        trace_id,
        tx_now,
        tx_lt,
        vault_address,
        vault_name,
        notification_result.owner_address AS owner_address,
        notification_result.burn_amount AS burn_amount,
        SUM(COALESCE(mint_result.mint_amount, 0)) AS total_mint_amount,
        notification_result.burn_amount - SUM(COALESCE(mint_result.mint_amount, 0)) AS real_burn_amount
    FROM parsed_results 
    GROUP BY 
        block_date,
        tx_hash,
        trace_id,
        tx_now,
        tx_lt,
        vault_address,
        vault_name,
        notification_result.owner_address,
        notification_result.burn_amount
),
withdraw_results AS (
    SELECT 
        br.block_date,
        br.tx_hash,
        br.trace_id,
        br.tx_now,
        br.tx_lt,
        br.vault_address,
        br.vault_name,
        br.owner_address,
        br.real_burn_amount AS burn_amount,
        SUM(COALESCE(
            {{ ton_from_boc('a.body_boc', [
                ton_begin_parse(),
                ton_skip_bits(32),
                ton_load_uint(64, 'query_id'),
                ton_load_uint(32, 'action_op'),
                ton_return_if_neq('action_op', 3406020527),
                ton_load_uint(16, 'error_code'),
                ton_return_if_neq('error_code', 0),
                ton_load_address('asset'),
                ton_load_coins('amount'),
                ton_load_coins('share')
            ]) }}.amount, 0)) AS withdraw_amount
    FROM burn_results br
    LEFT JOIN all_messages a
        ON br.trace_id = a.trace_id 
        AND br.vault_address = a.vault_address 
        AND a.message_type = 'action_notification'
    GROUP BY 
        br.block_date,
        br.tx_hash,
        br.trace_id,
        br.tx_now,
        br.tx_lt,
        br.vault_address,
        br.vault_name,
        br.owner_address,
        br.real_burn_amount
)
SELECT 
    wr.block_date,
    wr.tx_hash,
    wr.trace_id,
    wr.tx_now,
    wr.tx_lt,
    wr.vault_address,
    wr.vault_name,
    wr.owner_address,
    wr.burn_amount,
    wr.withdraw_amount + COALESCE(
        {{ ton_from_boc('t.body_boc', [
            ton_begin_parse(),
            ton_skip_bits(32),
            ton_load_uint(64, 'query_id'),
            ton_load_coins('amount')
        ]) }}.amount, 0) AS total_withdraw_amount,
    1.0 * (wr.withdraw_amount + COALESCE(
        {{ ton_from_boc('t.body_boc', [
            ton_begin_parse(),
            ton_skip_bits(32),
            ton_load_uint(64, 'query_id'),
            ton_load_coins('amount')
        ]) }}.amount, 0)) / wr.burn_amount AS withdraw_to_burn_ratio
FROM withdraw_results wr
LEFT JOIN all_messages t
    ON wr.trace_id = t.trace_id 
    AND wr.vault_address = t.vault_address 
    AND t.message_type = 'transfer'