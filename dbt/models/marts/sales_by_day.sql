with base_sales as (select revenue,transaction_id, day_of_week
from {{ref('stg_sales')}}) ,

total_revenue_per_day as (
    select sum(revenue) as total_revenue,count(transaction_id) as transaction_count,day_of_week
    from base_sales
    group by day_of_week
    order by total_revenue desc
)

select round(total_revenue,2) as total_revenue,transaction_count,day_of_week  
from total_revenue_per_day



