{{ config(
       schema = 'factorial_ton'
       , alias = 'strategy_vault_deposit'
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

WITH factorial_ton_strategy_vaults AS (
    {{ factorial_ton_strategy_vaults() }}
),
parsed_boc AS (
    SELECT M.block_date, M.tx_hash, M.trace_id, M.tx_now, M.tx_lt, M.destination, opcode, vault_address, vault_name, body_boc
    FROM {{ source('ton', 'messages') }} M
    JOIN factorial_ton_strategy_vaults ON M.source = vault_address
    WHERE M.direction = 'out' AND M.value IS NULL -- supply event id: 0xf9471134
    AND M.block_date >= TIMESTAMP '2025-06-12' -- protocol launch
    {% if is_incremental() %}
        AND {{ incremental_predicate('M.block_date') }}
    {% endif %}
),
trace_opcodes AS (
    SELECT 
        trace_id,
        CASE 
            WHEN COUNT(CASE WHEN opcode = 395134233 THEN 1 END) > 0 THEN 'deposit'
            ELSE 'unknown'
        END as transaction_type
    FROM {{ source('ton', 'messages') }} M
    WHERE M.trace_id IN (SELECT trace_id FROM parsed_boc) AND M.source IN (SELECT vault_address FROM parsed_boc)
    AND M.block_date >= TIMESTAMP '2025-06-12'
    {% if is_incremental() %}
        AND {{ incremental_predicate('M.block_date') }}
    {% endif %}
    GROUP BY trace_id
),
parse_output AS (
    SELECT {{ ton_from_boc('body_boc', [
    ton_begin_parse(),
    ton_load_address('owner_address'),
    ton_load_address('asset_address'),
    ton_load_coins('amount'),
    ton_load_coins('share')
    ]) }} as result, * FROM parsed_boc
)
SELECT 
    p.block_date, 
    p.tx_hash, 
    p.trace_id, 
    p.tx_now, 
    p.tx_lt, 
    p.vault_address, 
    p.vault_name,
    p.result.owner_address, 
    p.result.asset_address, 
    p.result.amount, 
    p.result.share
FROM parse_output p
LEFT JOIN trace_opcodes t ON p.trace_id = t.trace_id
WHERE p.result.owner_address != 'addr_none' AND t.transaction_type = 'deposit'