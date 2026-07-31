import pandas as pd
import random
from datetime import datetime, timedelta
import os

random.seed(42)

menu = {
    "Coffee":       {"category": "Drink", "price": 4.5},
    "Tea":          {"category": "Drink", "price": 4.0},
    "Muffin":       {"category": "Food", "price": 5.0},
    "Croissant":    {"category": "Food", "price": 5.5},
    "Banana Bread": {"category": "Food", "price": 6.0},
}
items = list(menu.keys())

start_date = datetime(2026, 7, 1)
end_date = datetime.now()  # today

output_dir = "daily_files"
os.makedirs(output_dir, exist_ok=True)

transaction_id_counter = 1
current_date = start_date

while current_date <= end_date:
    day_of_week = current_date.strftime("%A")
    rows = []

    base_transactions = 120
    if day_of_week == "Tuesday":
        base_transactions = int(base_transactions * 0.6)
    if day_of_week in ["Saturday", "Sunday"]:
        base_transactions = int(base_transactions * 1.2)

    num_transactions = base_transactions + random.randint(-10, 10)

    for _ in range(num_transactions):
        hour = random.randint(7, 16)
        minute = random.randint(0, 59)
        txn_time = f"{hour:02d}:{minute:02d}"

        if hour >= 14 and random.random() < 0.7:
            possible_items = [i for i in items if i != "Coffee"]
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
            "transaction_id": transaction_id_counter,
            "date": current_date.strftime("%Y-%m-%d"),
            "time": txn_time,
            "day_of_week": day_of_week,
            "item": item,
            "category": category,
            "price": price,
            "quantity": quantity,
            "revenue": revenue,
        })
        transaction_id_counter += 1

    day_df = pd.DataFrame(rows).sort_values(by="time").reset_index(drop=True)
    filename = f"{output_dir}/sales_{current_date.strftime('%Y-%m-%d')}.csv"
    day_df.to_csv(filename, index=False)
    print(f"Wrote {len(day_df)} transactions to {filename}")

    current_date += timedelta(days=1)

print(f"\nDone. Generated files for {(end_date - start_date).days + 1} days.")