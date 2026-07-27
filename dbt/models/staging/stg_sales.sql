select
  transaction_id,
  date,
  time,
  day_of_week,
  item,
  category,
  price,
  quantity,
  revenue
from {{ source('cafe_data', 'sales_raw') }}