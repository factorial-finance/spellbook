{%- macro factorial_ton_lending_vaults()
-%}
{# Contains strategy vault addresses #}

SELECT vault_address, vault_name FROM (VALUES 
    ('0:0343A25C2B434CB8D339BB009C4BD6E3727D914EF731608663365848872C14AD', 'TON Lending Vault'),
    ('0:06B609EBD46D170E294651170E077A54865F8BA3FFC9F936893F42B87B2F1CB9', 'USDT Lending Vault')
    ) AS T(vault_address, vault_name)

{%- endmacro -%}
