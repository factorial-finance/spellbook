{{ config(
       schema = 'factorial_ton'
       , alias = 'lending_vault_deposit'
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
            WHEN M.direction = 'in' AND M.opcode = 1935855772 THEN 'notification'
            WHEN M.direction = 'out' AND M.opcode = 395134233 THEN 'mint'
        END AS message_type
    FROM {{ source('ton', 'messages') }} M
    JOIN factorial_ton_lending_vaults v
        ON (M.direction = 'in' AND M.opcode = 1935855772 AND M.destination = v.vault_address)
        OR (M.direction = 'out' AND M.opcode = 395134233 AND M.source = v.vault_address)
    WHERE M.block_date >= TIMESTAMP '2025-07-21'
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
    JOIN all_messages m 
        ON n.trace_id = m.trace_id 
        AND n.vault_address = m.vault_address  -- 같은 vault
        AND n.message_type = 'notification' 
        AND m.message_type = 'mint'
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
            ton_load_coins('amount'),
            ton_load_address('owner_address')
        ]) }} AS notification_result,
        {{ ton_from_boc('mint_boc', [
            ton_begin_parse(),
            ton_skip_bits(32),
            ton_load_uint(64, 'query_id'),
            ton_load_coins('share')
        ]) }} AS mint_result
    FROM joined_messages
)
SELECT 
    block_date,
    tx_hash,
    trace_id,
    tx_now,
    tx_lt,
    vault_address,
    vault_name,
    notification_result.owner_address AS owner_address,
    notification_result.amount AS amount,
    mint_result.share AS share
FROM parsed_results
WHERE mint_result.share IS NOT NULL