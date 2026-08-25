import gzip
import json
import os
import uuid
from datetime import datetime, timedelta
import numpy as np
import pandas as pd
from faker import Faker

def generate_synthetic_census(num_records=100000, output_filename="census_batch_001.json.gz"):
    """
    Generates millions of highly realistic US Census records efficiently.
    Includes intentional data quality anomalies, structural JSON layout,
    and properly correlated demographic variables for Snowflake testing.
    """
    print(f"🚀 Initializing generation engine for {num_records:,} records...")
    fake = Faker()
    
    # 1. Generate realistic geographical weights based on real-world populations
    # Higher weights given to more populated states
    states = ['CA', 'TX', 'FL', 'NY', 'PA', 'IL', 'OH', 'GA', 'NC', 'MI']
    state_weights = [0.15, 0.12, 0.10, 0.09, 0.07, 0.06, 0.06, 0.05, 0.05, 0.05]
    chosen_states = np.random.choice(states, size=num_records, p=state_weights)

    # 2. Vectorized demographic distributions using NumPy
    print("🧠 Computing demographic relationships and PII attributes...")
    ages = np.random.randint(18, 90, size=num_records)
    
    # Correlate income distributions with age vectors (adding noise for realism)
    base_income = 35000 + (ages * 650)
    income_noise = np.random.normal(0, 15000, size=num_records)
    incomes = np.clip(base_income + income_noise, 0, 350000).astype(int)
    
    # Categorical pools for fast randomization
    genders = ['M', 'F', 'NB', 'U']
    gender_weights = [0.48, 0.49, 0.02, 0.01]
    chosen_genders = np.random.choice(genders, size=num_records, p=gender_weights)
    
    employment_statuses = ['Employed', 'Unemployed', 'Retired', 'Student', 'Self-Employed']
    employment_weights = [0.60, 0.05, 0.20, 0.10, 0.05]
    chosen_employment = np.random.choice(employment_statuses, size=num_records, p=employment_weights)

    # 3. Build vectorized dataframe structure
    print("📋 Assembling primary dataframe structures...")
    df = pd.DataFrame({
        'record_id': [str(uuid.uuid4()) for _ in range(num_records)],
        'ssn': [f"{np.random.randint(100,999):03d}-{np.random.randint(10,99):02d}-{np.random.randint(1000,9999):04d}" for _ in range(num_records)],
        'first_name': [fake.first_name() for _ in range(num_records)],
        'last_name': [fake.last_name() for _ in range(num_records)],
        'age': ages,
        'gender': chosen_genders,
        'state': chosen_states,
        'annual_income': incomes,
        'employment_status': chosen_employment,
        'ingest_timestamp': [datetime.utcnow().isoformat() for _ in range(num_records)]
    })

    # 4. Introduce "Real-World" Data Pipeline Inconsistencies
    # Hiring managers look for pipelines that gracefully handle messy production files!
    print("⚠️ Injecting data quality anomalies (null values, spaces, casing mismatches)...")
    
    # Introduce random missing incomes (approx 2% Nulls)
    df.loc[df.sample(frac=0.02).index, 'annual_income'] = None
    
    # Mess up structural string formats on names (Simulating dirty data collection)
    # 3% of first names get messy spacing, 2% of last names are uppercased
    df.loc[df.sample(frac=0.03).index, 'first_name'] = df['first_name'] + "   "
    df.loc[df.sample(frac=0.02).index, 'last_name'] = df['last_name'].str.upper()

    # 5. Export directly as an optimized, compressed Line-Delimited JSON file
    # This structure exactly matches Snowflake's ideal ingestion format for VARIANT types.
    print(f"💾 Compressing and streaming records directly into {output_filename}...")
    
    with gzip.open(output_filename, 'wt', encoding='utf-8') as f:
        # Orient="records" lines=True formats records line-by-line: {"id":1}\n{"id":2}
        df.to_json(f, orient='records', lines=True)
        
    print(f"✅ Success! File '{output_filename}' generated ({os.path.getsize(output_filename) / (1024*1024):.2f} MB).")

if __name__ == "__main__":
    # Generate a demo batch of 100,000 records. Increase to 1,000,000 for true load testing!
    generate_synthetic_census(num_records=100000, output_filename="census_batch_001.json.gz")
