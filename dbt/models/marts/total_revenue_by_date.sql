with base_sales as (select revenue,transaction_id, day_of_week,date
from {{ref('stg_sales')}}) ,

total_revenue_per_day as (
    select sum(revenue) as total_revenue,count(transaction_id) as transaction_count,day_of_week,date
    from base_sales
    group by date
    order by total_revenue desc
)

select total_revenue,transaction_count,day_of_week,date
from total_revenue_per_day



