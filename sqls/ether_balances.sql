with nested_failed_traces as (
    select child.transaction_hash, child.trace_address, parent.error
    from ethereum_blockchain.traces parent
    join ethereum_blockchain.traces child
    on starts_with(child.trace_address, concat(parent.trace_address, ','))
    and child.transaction_hash = parent.transaction_hash
    where parent.error is not null
),
full_traces as (
    select *, if((traces.error is not null or nested_failed_traces.error is not null), true, false) as is_error
    from `ethereum_blockchain.traces` as traces
    left join nested_failed_traces on nested_failed_traces.transaction_hash = traces.transaction_hash
    and nested_failed_traces.trace_address = traces.trace_address

),
double_entry_book as (
    -- debits
    select to_address as address, value as value, block_timestamp
    from full_traces
    where to_address is not null
    and is_error
    and (call_type not in ('delegatecall', 'callcode', 'staticcall') or call_type is null)
    union all
    -- credits
    select from_address as address, -value as value, block_timestamp
    from full_traces
    where from_address is not null
    and not is_error
    and (call_type not in ('delegatecall', 'callcode', 'staticcall') or call_type is null)
    union all
    -- transaction fees debits
    select miner as address, sum(cast(receipt_gas_used as numeric) * cast(gas_price as numeric)) as value, blocks.timestamp
    from `bigquery-public-data.ethereum_blockchain.transactions` as transactions
    join `bigquery-public-data.ethereum_blockchain.blocks` as blocks on blocks.number = transactions.block_number
    group by blocks.timestamp, blocks.miner
    union all
    -- transaction fees credits
    select from_address as address, -(cast(receipt_gas_used as numeric) * cast(gas_price as numeric)) as value, block_timestamp
    from `bigquery-public-data.ethereum_blockchain.transactions`
),
balances as (
  select address, sum(value) as balance, count(*) as transaction_count
  from double_entry_book
  group by address
)
select balances.address, balances.balance, balances.transaction_count
from balances
where balance > 0
order by balance desc
limit 10
