{%- macro factorial_ton_strategy_vaults()
-%}
{# Contains strategy vault addresses #}

SELECT vault_address, vault_name FROM (VALUES 
    ('0:EDC50AA4808450411E615A5AD0C6224CB4BC23477AC460D5016C472F3C3C02B3', 'TON Multiply Vault')
    ) AS T(vault_address, vault_name)

{%- endmacro -%}
