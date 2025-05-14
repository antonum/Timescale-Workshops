-- # Analyze financial tick data
--
--
-- This notebook is an adaptation of https://docs.timescale.com/tutorials/latest/financial-tick-data/
--
-- The financial industry is extremely data-heavy and relies on real-time and historical data for decision-making, risk assessment, fraud detection, and market analysis. Timescale simplifies management of these large volumes of data, while also providing you with meaningful analytical insights and optimizing storage costs.
--  
--  To analyze financial data, you can chart the open, high, low, close, and volume (OHLCV) information for a financial asset. Using this data, you can create candlestick charts that make it easier to analyze the price changes of financial assets over time. You can use candlestick charts to examine trends in stock, cryptocurrency, or NFT prices.
--  
-- In this tutorial, you use real raw financial data provided by Twelve Data, create an aggregated candlestick view, query the aggregated data.
-- 
-- ## Prerequisites
-- To follow the steps on this page:
--
-- Create a target Timescale Cloud service with time-series and analytics enabled.
-- https://console.cloud.timescale.com/signup
-- 
-- You need your connection details like `"postgres://tsdbadmin:xxxxxxx.yyyyy.tsdb.cloud.timescale.com:39966/tsdb?sslmode=require"` 
-- 
-- Alternatevely you can use self-hosted TimescaleDB. In the Google Colab environment we will install TimescaleDB and use it as a local database.
--
-- ## About OHLCV data and candlestick charts
-- The financial sector regularly uses candlestick charts to visualize the price change of an asset. 
-- Each candlestick represents a time period, such as one minute or one hour, and shows how the asset's price changed during that time.
--
-- Candlestick charts are generated from the open, high, low, close, and volume data for each financial asset during the time period. 
-- This is often abbreviated as OHLCV:
-- - Open: opening price
-- - High: highest price
-- - Low: lowest price
-- - Close: closing price
-- - Volume: volume of transactions
--
-- ![candlestick data](https://assets.timescale.com/docs/images/tutorials/intraday-stock-analysis/timescale_cloud_candlestick.png)

-- ## Setup
-- Drop tables and associated objects
DROP TABLE IF EXISTS crypto_ticks CASCADE;
DROP TABLE IF EXISTS crypto_assets CASCADE;

-- Create a standard PostgreSQL table to store the real-time cryptocurrency data:
CREATE TABLE crypto_ticks (
    "time" TIMESTAMPTZ,
    symbol TEXT,
    price DOUBLE PRECISION,
    day_volume NUMERIC
);

-- Convert the standard table into a hypertable partitioned on the time column using the create_hypertable() function provided by Timescale. 
-- You must provide the name of the table and the column in that table that holds the timestamp data to use for partitioning:
SELECT create_hypertable('crypto_ticks', by_range('time'));
-- Create a standard PostgreSQL table for relational data
CREATE TABLE crypto_assets (
    symbol TEXT UNIQUE,
    "name" TEXT
);
-- ## Load financial data
-- This tutorial uses real-time cryptocurrency data, also known as tick data, from Twelve Data. 
-- To ingest data into the tables that you created, you need to download the dataset, 
-- then upload the data to your Timescale Cloud service.
\! wget https://assets.timescale.com/docs/downloads/candlestick/crypto_sample.zip

\! unzip -o crypto_sample.zip
-- Load the CSV files into the tables (takes 30-40 seconds)
-- At the psql prompt, use the COPY command to transfer data into your Timescale instance. 
-- If the .csv files aren't in your current directory, specify the file paths in these commands:
\COPY crypto_ticks FROM 'tutorial_sample_tick.csv' CSV HEADER;

\COPY crypto_assets FROM 'tutorial_sample_assets.csv' CSV HEADER;
-- ## Preview data
SELECT * FROM crypto_ticks LIMIT 10;
-- Preview the reference data
SELECT * FROM crypto_assets LIMIT 10;
-- ## Create indexes
-- Indexes are used to speed up the retrieval of data from a database table.
-- In this case, you create an index on the symbol column of the crypto_assets and crypto_ticks tables.
-- Hypertables automatically create indexes on the time column, so you don't need to create an index on that column.
CREATE INDEX ON crypto_assets (symbol);
CREATE INDEX ON crypto_ticks (symbol);
-- ## Examine hypertable details (psql command)
-- Note that hypertable includes multiple partitions (chunks) of data.
--
-- You can also see two indices created on the time column and the symbol column.
\d+ crypto_ticks 
-- ## Examine Hypertable partitions
-- Timescale provides SQL API (functions, views, procedures) to manage hypertables and chunks.
-- The timescaledb_information.chunks view provides information about the chunks of a hypertable.
SELECT 
    chunk_name, 
    range_start, 
    range_end, 
    is_compressed 
FROM 
    timescaledb_information.chunks
WHERE 
    hypertable_name = 'crypto_ticks';
-- ## JOIN Hypertable and regular table
-- While organized differently internally, hypertables are fully-featured PostgreSQL tables.
-- You can use standard SQL to query the data in a hypertable, including joining it with other tables.
-- In this example, you join the crypto_ticks hypertable with the crypto_assets table to get the name of the asset.
--
-- Optionally add EXPLAIN ANALYZE to see the query plan.
-- You would see that the query goes through internal chunks of the hypertable like `_hyper_60_285_chunk`
  -- EXPLAIN ANALYZE 
SELECT t.time, t.symbol, t.price, t.day_volume, a.name
FROM crypto_ticks t
JOIN crypto_assets a
ON t.symbol = a.symbol
ORDER BY t.time DESC
LIMIT 10;
-- Enable timing tracking for the PSQL session
\timing on
-- ## Calculate one-day candlestick data on non-compresssed Hypertable
SELECT
    time_bucket('1 day', time) AS bucket,
    symbol,
    FIRST(price, time) AS "open",
    MAX(price) AS high,
    MIN(price) AS low,
    LAST(price, time) AS "close",
    LAST(day_volume, time) AS day_volume
FROM crypto_ticks
WHERE symbol = 'BTC/USD' AND time >= NOW() - INTERVAL '14 days'
GROUP BY bucket, symbol
ORDER BY bucket;
-- Remember the time it took to run the query. Later we will compare the performance of the same query 
-- on compressed data and preaggregated data in Continuos aggregate
-- ## Enable Columnarstore (Compression)
-- To enable columnarstore, you need to set the timescaledb.enable_columnstore parameter to true.
-- This parameter is set at the table level, so you need to run the ALTER TABLE command on the crypto_ticks hypertable.
-- The timescaledb.compress_orderby parameter specifies the order in which the data is compressed.
-- The timescaledb.segmentby parameter specifies the column by which the data is segmented.
-- The segmentby column is used to group the data into segments, which are then compressed separately.
ALTER TABLE crypto_ticks 
SET (
    timescaledb.enable_columnstore = true, 
    timescaledb.segmentby = 'symbol',
    timescaledb.compress_orderby='time DESC'
);
-- Enambling a columnarstore for the table by itself does not compress the data.
-- You can either manually compress hypertable chunks or create a policy to automatically compress chunks.
-- The compress_chunk() function compresses the chunk of data in the hypertable.
-- 
-- ### Manually compress all the chunks of the hypertable
-- TODO: switch to convert_to_columnarstore()?
SELECT compress_chunk(c, true) FROM show_chunks('crypto_ticks') c;
 -- SELECT decompress_chunk(c, true) FROM show_chunks('crypto_ticks') c;

-- ### Automatically compress Hypertable with a policy
-- Create a job that automatically converts chunks in a hypertable to the columnstore older than 1 day
-- This is a preferred way to compress data in production
CALL add_columnstore_policy('crypto_ticks', after => INTERVAL '1d');

-- ## Storage saved by the compression
-- The hypertable_compression_stats() function returns the size of the compressed and uncompressed data in the hypertable.
SELECT 
  pg_size_pretty(before_compression_total_bytes) as before,
  pg_size_pretty(after_compression_total_bytes) as after
FROM hypertable_compression_stats('crypto_ticks');

-- In our case the compression ratio is ~10x
-- 
-- In practice that means that to store 1TB of data in a hypertable, you need just 100GB of storage.
--  
-- ## Calculate one-day candlestick data on compresssed Hypertable
-- This is the same query as above, but now it runs on compressed data.
SELECT
    time_bucket('1 day', time) AS bucket,
    symbol,
    FIRST(price, time) AS "open",
    MAX(price) AS high,
    MIN(price) AS low,
    LAST(price, time) AS "close",
    LAST(day_volume, time) AS day_volume
FROM crypto_ticks
WHERE symbol = 'BTC/USD' AND time >= NOW() - INTERVAL '14 days'
GROUP BY bucket, symbol
ORDER BY bucket;
-- The query runs on columnar/compressed data and it is faster then the same query on uncompressed data

-- ## Create a continuous aggregate 
-- Continuous aggregates are a TimescaleDB feature that allows you to pre-aggregate data in a hypertable and store the results in a materialized view.
-- This allows you to query the pre-aggregated data instead of the raw data, which can significantly improve query performance. 
-- Continuous aggregates are automatically updated as new data is ingested into the hypertable.
CREATE MATERIALIZED VIEW one_day_candle
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
    SELECT
        time_bucket('1 day', time) AS bucket,
        symbol,
        FIRST(price, time) AS "open",
        MAX(price) AS high,
        MIN(price) AS low,
        LAST(price, time) AS "close",
        LAST(day_volume, time) AS day_volume
    FROM crypto_ticks
    GROUP BY bucket, symbol;

-- ### Create continuous aggregate policy
-- The add_continuous_aggregate_policy() function creates a policy that automatically refreshes the continuous aggregate view.
--
-- The start_offset and end_offset parameters specify the time range for the job, updating the aggregate view.
--
-- The schedule_interval parameter specifies how often the continuous aggregate view is refreshed.
SELECT add_continuous_aggregate_policy('one_day_candle',
    start_offset => INTERVAL '3 days',
    end_offset => INTERVAL '1 day',
    schedule_interval => INTERVAL '1 day');
-- ## Query continuous aggregate
-- This query delivers the same results as the previous query, 
-- but it runs on the continuous aggregate view instead of the raw data.
-- it is significantly faster than the same query on the raw data.
SELECT * FROM one_day_candle
WHERE symbol = 'BTC/USD' AND bucket >= NOW() - INTERVAL '14 days'
ORDER BY bucket;

-- ## Real Time Continuous Aggregates
-- The continuous aggregate view is automatically updated as new data is ingested into the hypertable.
-- Let's insert a new row into the crypto_ticks table and see how the continuous aggregate view is updated.
INSERT INTO crypto_ticks (time, symbol, price, day_volume)
VALUES (NOW()+INTERVAL '1day', 'BTC/USD', 110000, 30750246);

SELECT * FROM one_day_candle
WHERE symbol = 'BTC/USD' AND bucket >= NOW() - INTERVAL '14 days'
ORDER BY bucket;
-- As you can see, the continuous aggregate view is automatically updated with the new data.
-- This is the stark contrast to standard Postgres Materialized view that needs to be refreshed manually
-- and does not support real-time updates.