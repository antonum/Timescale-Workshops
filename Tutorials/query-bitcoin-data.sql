-- #############################################
-- ## TimescaleDB Blockchain Query Tutorial ##
-- #############################################
--
-- Source: Synthesized from Timescale Documentation snippets found via Google Search
-- Based on: https://docs.timescale.com/tutorials/latest/blockchain-query/
--
-- This script guides you through setting up a dataset, querying it,
-- and optionally compressing it using TimescaleDB for Bitcoin blockchain data.

-- ==========================
-- == Setting up your dataset ==
-- ==========================

-- -- Prerequisites:
-- -- * A running TimescaleDB instance (Timescale Cloud or self-hosted).
-- -- * psql command-line utility installed and connected to your database.

-- -- Create a standard PostgreSQL table to store the Bitcoin blockchain data.
-- -- The dataset contains around 1.5 million Bitcoin transactions for five days.
-- -- It includes information about each transaction, value in satoshi,
-- -- if it's a coinbase transaction, and miner rewards.
CREATE TABLE transactions (
    time TIMESTAMPTZ,
    block_id INT,
    hash TEXT,
    size INT,
    weight INT,
    is_coinbase BOOLEAN,
    output_total BIGINT,
    output_total_usd DOUBLE PRECISION,
    fee BIGINT,
    fee_usd DOUBLE PRECISION,
    details JSONB
);

-- -- Convert the standard table into a hypertable partitioned on the time column.
-- -- Hypertables are the core of TimescaleDB, enabling efficient handling of time-series data
-- -- by automatically partitioning data by time.
SELECT create_hypertable('transactions', by_range('time'));
-- -- Note: The by_range dimension builder is available in TimescaleDB 2.13+.
-- -- For older versions, you might use: SELECT create_hypertable('transactions', 'time');

-- -- When you create a hypertable, an index on the time column is automatically created.
-- -- However, filtering on other columns is common. Create additional indexes for performance.

-- -- Create an index on the hash column for faster individual transaction lookups.
CREATE INDEX hash_idx ON public.transactions USING HASH (hash);

-- -- Create an index on the block_id column for faster block-level queries.
CREATE INDEX block_idx ON public.transactions (block_id);

-- -- Create a unique index on time and hash to prevent duplicate records.
CREATE UNIQUE INDEX time_hash_idx ON public.transactions (time, hash);

-- -- Download the sample dataset.
-- -- This file contains a .csv file with Bitcoin transactions for five days.
-- -- (Link mentioned in docs: bitcoin_sample.zip - Download manually)
-- -- --> Download bitcoin_sample.zip

\! wget https://assets.timescale.com/docs/downloads/bitcoin-blockchain/bitcoin_sample.zip


-- -- Unzip the downloaded file in your terminal.
-- -- In psql, you can execute shell commands using \!
-- -- Make sure the zip file is in the current directory accessible by psql.
\! unzip bitcoin_sample.zip

-- -- Load the data from the CSV file into the transactions table using the COPY command.
-- -- Ensure 'tutorial_bitcoin_sample.csv' is in the correct path accessible by the psql client.
\COPY transactions FROM 'tutorial_bitcoin_sample.csv' CSV HEADER;
-- -- This might take a few minutes depending on your connection and client resources.

-- -- Cleanup
\! rm tutorial_bitcoin_sample.csv bitcoin_sample.zip

-- ==========================
-- == Querying your dataset ==
-- ==========================

-- -- Now that the data is loaded, you can run queries.

-- -- Query for the five most recent non-coinbase transactions.
SELECT time, hash, block_id, weight
FROM transactions
WHERE is_coinbase IS NOT TRUE
ORDER BY time DESC
LIMIT 5;

-- -- Query to get transaction count, total weight, and total USD value for the 5 most recent blocks.
-- -- This uses a Common Table Expression (CTE) to first find the latest blocks.
WITH recent_blocks AS (
    SELECT block_id
    FROM transactions
    WHERE is_coinbase IS TRUE
    ORDER BY time DESC
    LIMIT 5
)
SELECT
    t.block_id,
    count(*) AS transaction_count,
    SUM(weight) AS block_weight,
    SUM(output_total_usd) AS block_value_usd
FROM transactions t
INNER JOIN recent_blocks b ON b.block_id = t.block_id
GROUP BY t.block_id;

-- -- (Add more example queries from the "Querying your dataset" section of the tutorial if available/needed)
-- -- Example: Analyze data using time_bucket() or other hyperfunctions (Referenced in related Timescale docs)
SELECT time_bucket('1 day', time) AS bucket, avg(output_total_usd)
FROM transactions
GROUP BY bucket
ORDER BY bucket DESC;

-- ==================================
-- == Bonus: Store data efficiently ==
-- ==================================

-- -- TimescaleDB allows compressing data to save storage space and potentially improve query performance
-- -- on large datasets. Compression converts data into a columnar format.

-- -- Configure compression on the hypertable.
-- -- 'segment by' columns define how data is grouped within compressed chunks.
-- -- 'order by' columns define the sort order within compressed chunks, improving compression ratios.
ALTER TABLE transactions SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'block_id', -- Example: segment by block_id
    timescaledb.compress_orderby = 'time DESC'     -- Example: order by time descending
);

-- -- Create a policy to automatically compress chunks older than a certain age (e.g., 7 days).
-- -- The database will periodically run this policy in the background.
SELECT add_compression_policy('transactions', INTERVAL '7 days');

-- -- Note: After enabling compression, older data chunks will be compressed according to the policy.
-- -- Queries generally work transparently on compressed and uncompressed data.

-- -- measure the effect of compression
SELECT 
    'transactions' AS hypertable, 
    pg_size_pretty(before_compression_total_bytes) AS before_compression, 
    pg_size_pretty(after_compression_total_bytes) AS after_compression 
FROM hypertable_compression_stats('transactions');

-- -- End of Tutorial Script