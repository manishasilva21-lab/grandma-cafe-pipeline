import pandas as pd
import random
from datetime import datetime, timedelta
from google.cloud import storage
import functions_framework

menu = {
    "Coffee":       {"category": "Drink", "price": 4.5},
    "Tea":          {"category": "Drink", "price": 4.0},
    "Muffin":       {"category": "Food", "price": 5.0},
    "Croissant":    {"category": "Food", "price": 5.5},
    "Banana Bread": {"category": "Food", "price": 6.0},
}
items = list(menu.keys())

BUCKET_NAME = "grandma-cafe-analytics-raw-data"

@functions_framework.http
def generate_daily_sales(request):
    # "Yesterday" — the day that just fully completed
    target_date = datetime.now() - timedelta(days=1)
    day_of_week = target_date.strftime("%A")

    rows = []
    transaction_id_start = int(target_date.strftime("%Y%m%d")) * 1000  # unique-ish per day

    base_transactions = 120
    if day_of_week == "Tuesday":
        base_transactions = int(base_transactions * 0.6)
    if day_of_week in ["Saturday", "Sunday"]:
        base_transactions = int(base_transactions * 1.2)

    num_transactions = base_transactions + random.randint(-10, 10)

    for i in range(num_transactions):
        hour = random.randint(7, 16)
        minute = random.randint(0, 59)
        txn_time = f"{hour:02d}:{minute:02d}"

        if hour >= 14 and random.random() < 0.7:
            possible_items = [x for x in items if x != "Coffee"]
        else:
            possible_items = items

        weights = []
        for item in possible_items:
            if item == "Muffin":
                weights.append(3)
            elif item == "Croissant":
                weights.append(1)
            else:
                weights.append(2)

        item = random.choices(possible_items, weights=weights, k=1)[0]
        price = menu[item]["price"]
        category = menu[item]["category"]
        quantity = random.choices([1, 2, 3], weights=[70, 25, 5], k=1)[0]
        revenue = round(price * quantity, 2)

        rows.append({
            "transaction_id": transaction_id_start + i,
            "date": target_date.strftime("%Y-%m-%d"),
            "time": txn_time,
            "day_of_week": day_of_week,
            "item": item,
            "category": category,
            "price": price,
            "quantity": quantity,
            "revenue": revenue,
        })

    df = pd.DataFrame(rows).sort_values(by="time").reset_index(drop=True)
    filename = f"sales_{target_date.strftime('%Y-%m-%d')}.csv"

    # Upload directly to GCS (no local disk needed)
    client = storage.Client()
    bucket = client.bucket(BUCKET_NAME)
    blob = bucket.blob(filename)
    blob.upload_from_string(df.to_csv(index=False), content_type="text/csv")

    return f"Generated {len(df)} transactions for {target_date.strftime('%Y-%m-%d')}, uploaded as {filename}", 200