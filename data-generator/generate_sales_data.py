import pandas as pd 
import random
from datetime import datetime, timedelta

random.seed(42) #makes results repeatable - same "random" data every run

#---menu setup----
#-- lookup table item name, category and price
menu = {
    "Coffee":    {"category": "Drink", "price": 4.5},
    "Tea":       {"category": "Drink", "price": 4.0},
    "Muffin":    {"category": "Food", "price": 5.0},
    "Croissant": {"category": "Food", "price": 5.5},
    "Banana Bread": {"category": "Food", "price": 6.0},
}

items = list(menu.keys())

start_date = datetime(2025,7,1)
end_date = datetime(2026,6,30)

rows = []
transaction_id = 1
current_date = start_date

#loops through everyday of the year, one day at a time
while current_date <= end_date:
    day_of_week = current_date.strftime("%A") #e.g "Tuesday"

    # --- Baseline number of transactions per day (how busy the cafe is oon that day) --
    base_transactions = 120

    # secret #1 : Tuesdays are slow (40% fewer transactions)
    if day_of_week == "Tuesday":
        base_transactions = int(base_transactions * 0.6)

    # secret #2 : Weekends are busiest (20% more transactions)
    if day_of_week in ["Saturday", "Sunday"]:
        base_transactions = int(base_transactions * 1.2)

    num_transactions = base_transactions + random.randint(-10, 10)

    # stimulation of sales for each day
    for _ in range(num_transactions):
        # --- Pick a random time during opening hours (7am - 5pm) ---
        hour = random.randint(7, 16)
        minute = random.randint(0, 59)
        txn_time = f"{hour:02d}:{minute:02d}"

        # Secret #3: Coffee sales drop sharply after 2pm
        if hour >= 14 and random.random() < 0.7:
            # after 2pm, 70% chance we skip coffee and pick something else
            possible_items = [i for i in items if i != "Coffee"]
        else:
            possible_items = items

 # Secret #4: Muffins outsell croissants 3:1
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
            "transaction_id": transaction_id,
            "date": current_date.strftime("%Y-%m-%d"),
            "time": txn_time,
            "day_of_week": day_of_week,
            "item": item,
            "category": category,
            "price": price,
            "quantity": quantity,
            "revenue": revenue,
        })
        transaction_id += 1

    current_date += timedelta(days=1)

df = pd.DataFrame(rows)
df = df.sort_values(by=["date", "time"]).reset_index(drop=True)
df.to_csv("sales_data.csv", index=False)

print(f"Generated {len(df)} transactions across {(end_date - start_date).days + 1} days.")
print(df.head(10))
