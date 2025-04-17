-- # Analyze the Bitcoin blockchain                                                           
-- 
-- ## Ingest data into a Timescale Cloud service                                              
-- 
-- This tutorial uses a dataset that contains Bitcoin blockchain data for the past five days,  
-- in a hypertable named `transactions`.                                                      
-- based on https://docs.timescale.com/tutorials/latest/blockchain-analyze/analyze-blockchain-query/
-- 
-- ### Prerequisites                                                                          
-- 
-- To follow the steps on this page:                                                          
-- 
-- - Create a target Timescale Cloud service with time-series and analytics enabled.          
-- - You need your connection details. This procedure also works for self-hosted TimescaleDB. 
-- 
-- ### Optimize time-series data in hypertables                                               
-- 
-- Hypertables are the core of Timescale. Hypertables enable Timescale to work efficiently    
-- with time-series data. Because Timescale is PostgreSQL, all the standard PostgreSQL tables,
-- indexes, stored procedures and other objects can be created alongside your Timescale       
-- hypertables. This makes creating and working with Timescale tables similar to standard     
-- PostgreSQL.                                                                                
-- 
-- 1. Create a standard PostgreSQL table to store the Bitcoin blockchain data using `CREATE TABLE`:

-- Create regular PostgreSQL table for transactions
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

-- Convert the regular table into a hypertable
SELECT create_hypertable('transactions', by_range('time'));


-- Create an index on the hash column to make queries for individual transactions faster:
CREATE INDEX hash_idx ON public.transactions USING HASH (hash);

-- Create an index on the block_id column to make block-level queries faster:
CREATE INDEX block_idx ON public.transactions (block_id);

-- Create a unique index on the time and hash columns to make sure you don't accidentally insert duplicate records:
CREATE UNIQUE INDEX time_hash_idx ON public.transactions (time, hash);

-- Download data
\! wget https://assets.timescale.com/docs/downloads/bitcoin-blockchain/bitcoin_sample.zip

-- Unzip data
\! unzip bitcoin_sample.zip

-- Load data into the transactions table
\COPY transactions FROM 'tutorial_bitcoin_sample.csv' CSV HEADER;

-- Cleanup
\! rm bitcoin_sample.zip
\! rm tutorial_bitcoin_sample.csv

-- # Analyze the Bitcoin blockchain                                                           
-- 
-- When you have your dataset loaded, you can create some continuous aggregates, and start    
-- constructing queries to discover what your data tells you. This tutorial uses Timescale    
-- hyperfunctions to construct queries that are not possible in standard PostgreSQL.          
-- 
-- In this section, you learn how to write queries that answer these questions:               
-- 
-- - Is there any connection between the number of transactions and the transaction fees?     
-- - Does the transaction volume affect the BTC-USD rate?                                     
-- - Do more transactions in a block mean the block is more expensive to mine?                
-- - What percentage of the average miner's revenue comes from fees compared to block         
--   rewards?                                                                                 
-- - How does block weight affect miner fees?                                                 
-- - What's the average miner revenue per block?                                              
-- 
-- You can use continuous aggregates to simplify and speed up your queries. For this tutorial,
-- you need three continuous aggregates, focusing on three aspects of the dataset: Bitcoin    
-- transactions, blocks, and coinbase transactions. In each continuous aggregate definition,  
-- the `time_bucket()` function controls how large the time buckets are. The examples all use 
-- 1-hour time buckets.                                                                       
-- 
-- ## Create continuous aggregates                                                            
-- 
-- ### Continuous aggregate: transactions                                                     

-- create a continuous aggregate called one_hour_transactions. This view holds aggregated data about each hour of transactions:
CREATE MATERIALIZED VIEW one_hour_transactions
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 hour', time) AS bucket,
   count(*) AS tx_count,
   sum(fee) AS total_fee_sat,
   sum(fee_usd) AS total_fee_usd,
   stats_agg(fee) AS stats_fee_sat,
   avg(size) AS avg_tx_size,
   avg(weight) AS avg_tx_weight,
   count(
         CASE
            WHEN (fee > output_total) THEN hash
            ELSE NULL
         END) AS high_fee_count
  FROM transactions
  WHERE (is_coinbase IS NOT TRUE)
GROUP BY bucket;

-- Add a refresh policy to keep the continuous aggregate up-to-date:
SELECT add_continuous_aggregate_policy('one_hour_transactions',
   start_offset => INTERVAL '3 hours',
   end_offset => INTERVAL '1 hour',
   schedule_interval => INTERVAL '1 hour');

-- Create a continuous aggregate called one_hour_blocks. This view holds aggregated data about all the blocks that were mined each hour:
CREATE MATERIALIZED VIEW one_hour_blocks
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 hour', time) AS bucket,
   block_id,
   count(*) AS tx_count,
   sum(fee) AS block_fee_sat,
   sum(fee_usd) AS block_fee_usd,
   stats_agg(fee) AS stats_tx_fee_sat,
   avg(size) AS avg_tx_size,
   avg(weight) AS avg_tx_weight,
   sum(size) AS block_size,
   sum(weight) AS block_weight,
   max(size) AS max_tx_size,
   max(weight) AS max_tx_weight,
   min(size) AS min_tx_size,
   min(weight) AS min_tx_weight
FROM transactions
WHERE is_coinbase IS NOT TRUE
GROUP BY bucket, block_id;

-- Add a refresh policy to keep the continuous aggregate up-to-date:

SELECT add_continuous_aggregate_policy('one_hour_blocks',
   start_offset => INTERVAL '3 hours',
   end_offset => INTERVAL '1 hour',
   schedule_interval => INTERVAL '1 hour');


-- Create a continuous aggregate called one_hour_coinbase. This view holds aggregated data about all the transactions that miners received as rewards each hour:
CREATE MATERIALIZED VIEW one_hour_coinbase
WITH (timescaledb.continuous) AS
SELECT time_bucket('1 hour', time) AS bucket,
   count(*) AS tx_count,
   stats_agg(output_total, output_total_usd) AS stats_miner_revenue,
   min(output_total) AS min_miner_revenue,
   max(output_total) AS max_miner_revenue
FROM transactions
WHERE is_coinbase IS TRUE
GROUP BY bucket;

-- Add a refresh policy to keep the continuous aggregate up-to-date:
SELECT add_continuous_aggregate_policy('one_hour_coinbase',
   start_offset => INTERVAL '3 hours',
   end_offset => INTERVAL '1 hour',
   schedule_interval => INTERVAL '1 hour');


-- ## Analyze the data                                                                        

-- Is there any connection between the number of transactions and the transaction fees?       
-- Transaction fees are a major concern for blockchain users. If a blockchain is too expensive,
-- you might not want to use it. This query shows you whether there's any correlation between 
-- the number of Bitcoin transactions and the fees. The time range for this analysis is the   
-- last 2 days.                                                                               

-- If you choose to visualize the query in Grafana, you can see the average transaction volume
-- and the average fee per transaction, over time. These trends might help you decide whether 
-- to submit a transaction now or wait a few days for fees to decrease.                       


-- Query 1: Connection between transaction count and fees
SELECT
 bucket AS "time",
 tx_count as "tx volume",
 average(stats_fee_sat) as fees
FROM one_hour_transactions
WHERE bucket > date_add('2023-11-22 00:00:00+00', INTERVAL '-2 days')
ORDER BY 1;



-- Does the transaction volume affect the BTC-USD rate?                                       
-- In cryptocurrency trading, there's a lot of speculation. You can adopt a data-based trading
-- strategy by looking at correlations between blockchain metrics, such as transaction volume 
-- and the current exchange rate between Bitcoin and US Dollars.                              

-- If you choose to visualize the query in Grafana, you can see the average transaction volume,
-- along with the BTC to US Dollar conversion rate.                                           
-- Query 2: Transaction volume effect on BTC-USD rate
SELECT
 bucket AS "time",
 tx_count as "tx volume",
 total_fee_usd / (total_fee_sat*0.00000001) AS "btc-usd rate"
FROM one_hour_transactions
WHERE bucket > date_add('2023-11-22 00:00:00+00', INTERVAL '-2 days')
ORDER BY 1;



-- Do more transactions in a block mean the block is more expensive to mine?                  
-- The number of transactions in a block can influence the overall block mining fee. For this 
-- analysis, a larger time frame is required, so increase the analyzed time range to 5 days.  

-- if you choose to visualize the query in Grafana, you can see that the more transactions in 
-- a block, the higher the mining fee becomes.                                                

-- Query 3: Relationship between transaction count and mining cost
SELECT
 bucket as "time",
 avg(tx_count) AS transactions,
 avg(block_fee_sat)*0.00000001 AS "mining fee"
FROM one_hour_blocks
WHERE bucket > date_add('2023-11-22 00:00:00+00', INTERVAL '-5 days')
GROUP BY bucket
ORDER BY 1;



-- You can extend this analysis to find if there is the same correlation between block weight 
-- and mining fee. More transactions should increase the block weight, and boost the miner fee
-- as well.                                                                                   

-- If you choose to visualize the query in Grafana, you can see the same kind of high         
-- correlation between block weight and mining fee. The relationship weakens when the block   
-- weight gets close to its maximum value, which is 4 million weight units, in which case it's
-- impossible for a block to include more transactions.                                       

-- Finding if higher block weight means the block is more expensive to mine
SELECT
 bucket as "time",
 avg(tx_count) AS transactions,
 avg(block_fee_sat)*0.00000001 AS "mining fee"
FROM one_hour_blocks
WHERE bucket > date_add('2023-11-22 00:00:00+00', INTERVAL '-5 days')
GROUP BY bucket
ORDER BY 1;

-- What percentage of the average miner's revenue comes from fees compared to block rewards?  
-- In the previous queries, you saw that mining fees are higher when block weights and        
-- transaction volumes are higher. This query analyzes the data from a different perspective. 
-- Miner revenue is not only made up of miner fees, it also includes block rewards for mining 
-- a new block. This reward is currently 6.25 BTC, and it gets halved every four years. This  
-- query looks at how much of a miner's revenue comes from fees, compares to block rewards.   

-- If you choose to visualize the query in Grafana, you can see that most miner revenue       
-- actually comes from block rewards. Fees never account for more than a few percentage points
-- of overall revenue.                                                                        

WITH coinbase AS (
   SELECT block_id, output_total AS coinbase_tx FROM transactions
   WHERE is_coinbase IS TRUE and time > date_add('2023-11-22 00:00:00+00', INTERVAL '-5 days')
)
SELECT
   bucket as "time",
   avg(block_fee_sat)*0.00000001 AS "fees",
   FIRST((c.coinbase_tx - block_fee_sat), bucket)*0.00000001 AS "reward"
FROM one_hour_blocks b
INNER JOIN coinbase c ON c.block_id = b.block_id
GROUP BY bucket
ORDER BY 1;


-- How does block weight affect miner fees?                                                   
-- You've already found that more transactions in a block mean it's more expensive to mine.   
-- In this query, you ask if the same is true for block weights? The more transactions a block
-- has, the larger its weight, so the block weight and mining fee should be tightly correlated.
-- This query uses a 12-hour moving average to calculate the block weight and block mining fee
-- over time.                                                                                 

-- If you choose to visualize the query in Grafana, you can see that the block weight and     
-- block mining fee are tightly connected. In practice, you can also see the four million     
-- weight units size limit. This means that there's still room to grow for individual blocks, 
-- and they could include even more transactions.                                             
-- Finding how block weight affects miner fees
WITH stats AS (
   SELECT
       bucket,
       stats_agg(block_weight, block_fee_sat) AS block_stats
   FROM one_hour_blocks
   WHERE bucket > date_add('2023-11-22 00:00:00+00', INTERVAL '-5 days')
   GROUP BY bucket
)
SELECT
   bucket as "time",
   average_y(rolling(block_stats) OVER (ORDER BY bucket RANGE '12 hours' PRECEDING)) AS "block weight",
   average_x(rolling(block_stats) OVER (ORDER BY bucket RANGE '12 hours' PRECEDING))*0.00000001 AS "mining fee"
FROM stats
ORDER BY 1;

-- What's the average miner revenue per block?                                                
-- In this final query, you analyze how much revenue miners actually generate by mining a new 
-- block on the blockchain, including fees and block rewards. To make the analysis more       
-- interesting, add the Bitcoin to US Dollar exchange rate, and increase the time range.      
-- Query 6: average miner revenue per block, with a 12-hour moving average                    
SELECT
   bucket as "time",
   average_y(rolling(stats_miner_revenue) OVER (ORDER BY bucket RANGE '12 hours' PRECEDING))*0.00000001 AS "revenue in BTC",
    average_x(rolling(stats_miner_revenue) OVER (ORDER BY bucket RANGE '12 hours' PRECEDING)) AS "revenue in USD"
FROM one_hour_coinbase
WHERE bucket > date_add('2023-11-22 00:00:00+00', INTERVAL '-5 days')
ORDER BY 1;