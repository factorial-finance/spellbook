{% set blockchain = 'unichain' %}



{{
    config(
        schema = 'oneinch_' + blockchain,
        alias = 'ar',
        partition_by = ['block_month'],
        materialized = 'incremental',
        file_format = 'delta',
        incremental_strategy = 'merge',
        incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.block_time')],
        unique_key = ['blockchain', 'tx_hash', 'call_trace_address']
    )
}}



{{
    oneinch_ar_macro(
        blockchain = blockchain
    )
}}