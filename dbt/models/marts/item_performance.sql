with base_items as (
    select   
        item,
        quantity,
        revenue
    from {{ref('stg_sales')}}),

item_sales as (
    select sum(revenue) as total_revenue_per_item, item 
    from base_items
    group by item
    order by total_revenue_per_item desc 
),

final as (
    select item as item_name, round(total_revenue_per_item,2) as total_revenue_per_item
    from item_sales
)

select * from final