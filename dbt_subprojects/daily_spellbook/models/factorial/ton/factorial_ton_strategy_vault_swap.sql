{{ config(
       schema = 'factorial_ton'
       , alias = 'strategy_vault_swap'
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
    JOIN factorial_ton_strategy_vaults ON M.destination = vault_address
    WHERE M.direction = 'out' AND opcode = -349706169 -- supply event id: 0xf9471134
    AND M.block_date >= TIMESTAMP '2025-06-12' -- protocol launch
    {% if is_incremental() %}
        AND {{ incremental_predicate('M.block_date') }}
    {% endif %}
),
parse_output AS (
    SELECT {{ ton_from_boc('body_boc', [
    ton_begin_parse(),
    ton_skip_bits(32 + 64),
    ton_load_coins('rfq_index'),
    ton_load_uint(16, 'error_code'),
    ton_load_address('sell_asset_address'),
    ton_load_address('buy_asset_address'),
    ton_load_coins('sell_asset_amount'),
    ton_load_coins('buy_asset_amount')
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
    p.result.rfq_index,
    p.result.sell_asset_address,
    p.result.buy_asset_address,
    p.result.sell_asset_amount,
    p.result.buy_asset_amount
FROM parse_output p
WHERE p.result.error_code = 0