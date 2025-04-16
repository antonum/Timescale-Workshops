/***************************************************************************************
████████╗██╗███╗   ███╗███████╗███████╗ ██████╗ █████╗ ██╗     ███████╗
╚══██╔══╝██║████╗ ████║██╔════╝██╔════╝██╔════╝██╔══██╗██║     ██╔════╝
   ██║   ██║██╔████╔██║█████╗  ███████╗██║     ███████║██║     █████╗  
   ██║   ██║██║╚██╔╝██║██╔══╝  ╚════██║██║     ██╔══██║██║     ██╔══╝  
   ██║   ██║██║ ╚═╝ ██║███████╗███████║╚██████╗██║  ██║███████╗███████╗
   ╚═╝   ╚═╝╚═╝     ╚═╝╚══════╝╚══════╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚══════╝
                                                                       
██████╗ ███████╗███╗   ███╗ ██████╗ 
██╔══██╗██╔════╝████╗ ████║██╔═══██╗
██║  ██║█████╗  ██╔████╔██║██║   ██║
██║  ██║██╔══╝  ██║╚██╔╝██║██║   ██║
██████╔╝███████╗██║ ╚═╝ ██║╚██████╔╝
╚═════╝ ╚══════╝╚═╝     ╚═╝ ╚═════╝    Version 0.1.0   April 15, 2025
****************************************************************************************/

-------------------------------------------------------------------------------------------
-- SETUP for VS Code
-------------------------------------------------------------------------------------------
-- Connect to the TimescaleDB database

-- export TS_DEMO="postgres://tsdbadmin:xxxxxx@lpifmr8t11.ocssgijfrc.tsdb.cloud.timescale.com:32753/tsdb?sslmode=require"
-- optionally add the line above to your .zshrc or .bashrc file


-- In VS Code, create keyboard shortcut for running SQL code
-- 1. Open Keyboard Shortcuts (Ctrl + K Ctrl + S) or VSCode Settings -> Keyboard Shortcuts
-- 2. Search for "runSelectedText"
-- 3. Add a new keybinding (^S) for "Run Active File" with the command "workbench.action.terminal.runSelectedText"
-- 4. Save the keybinding
-- 5. Open the SQL file in VS Code
-- 6. Press the keybinding to run the SQL file in the integrated terminal
-- 7. The output will be displayed in the terminal

-- Now you can select specific query in the editor and press ^S to run it in the terminal

-- Run psql connecting to the DEMO DB
-- set options for psql
-- pagination off
-- timing on
-------------------------------------------------------------------------------------------
psql -d $TS_DEMO

-- set psql options
\pset pager off
\timing on
\! clear


-----------------------------------------------------------------------------------------
-- DEMO 1 Hypertable vs. Postgress Table
--
-- count the number of charging sessions for hypertable with 2.4B rows
-- and PostgreSQL table with 147M rows
-- This query counts the number of charging sessions for a specific date
-----------------------------------------------------------------------------------------


-- Timescale Hypertable (2.4B rows)
SELECT
   DATE(measurement_timestamp) as date,
   COUNT(DISTINCT charging_session_id) as num_charging_sessions
FROM ev_charger_telemetry
WHERE measurement_timestamp BETWEEN '2025-02-01 00:00:00' AND '2025-02-01 11:59:59'
GROUP BY date;


-- PostgreSQL Table (147M rows)
SELECT
   DATE(measurement_timestamp) as date,
   COUNT(DISTINCT charging_session_id) as num_charging_sessions
FROM ev_charger_telemetry_pg
WHERE measurement_timestamp BETWEEN '2025-02-01 00:00:00' AND '2025-02-01 11:59:59'
GROUP BY date;


-------------------------------------------------------------------------------------------
-- DEMO 2 Rowstore vs. Columnar store
--
-- TODO: Find query that shows significant diffeence between Columnar and Row storee
--  
-- To examine if there were any changes in CHARGING CONNECTOR TYPES at your favorite 
-- Charging Station throughout the year, e.g. End of 2024 vs. the beginning of the year
-------------------------------------------------------------------------------------------

-- Beginning of 2024 (ColumnStore)
SELECT
   charging_station_id,
   connector_type AS connector_type,
   AVG(energy_delivered_kwh) AS total_energy_delivered
FROM ev_charger_telemetry
WHERE
   charging_station_id IN (5, 10, 41) -- Replace with your desired station IDs
   AND 
   measurement_timestamp BETWEEN '2024-01-01' AND '2024-01-07'
GROUP BY charging_station_id, connector_type;

-- Beginning of 2025 (Rowstore)
SELECT
   charging_station_id,
   connector_type AS connector_type,
   AVG(energy_delivered_kwh) AS total_energy_delivered
FROM ev_charger_telemetry
WHERE
   charging_station_id IN (5, 10, 41) -- Replace with your desired station IDs
   AND 
   measurement_timestamp BETWEEN '2025-01-24' AND '2025-01-31'
GROUP BY charging_station_id, connector_type;


-------------------------------------------------------------------------------------------
-- DEMO 3 Hypertable size before and after compression
-------------------------------------------------------------------------------------------


SELECT 
    'ev-charger_telemetry' AS hypertable, 
    pg_size_pretty(before_compression_total_bytes) AS before_compression, 
    pg_size_pretty(after_compression_total_bytes) AS after_compression 
FROM hypertable_compression_stats('ev_charger_telemetry');


-------------------------------------------------------------------------------------------
-- DEMO 4 CAGG vs Hypertable
-------------------------------------------------------------------------------------------

-- C-Agg Query
SELECT
   day,
   SUM(total_energy_delivered_kwh) AS total_energy_delivered
FROM charging_summary_daily
WHERE charging_station_id = 1
AND day >= '2023-01-01 00:00:00'
AND day < '2025-01-01 00:00:00'
GROUP BY day
ORDER BY day
LIMIT 10;

-- Hypertable Query
SELECT
   time_bucket('1 day', measurement_timestamp) AS charging_date,
   SUM(energy_delivered_kwh) AS total_energy_delivered
FROM ev_charger_telemetry
WHERE measurement_timestamp >= '2023-01-01 00:00:00'
 AND measurement_timestamp < '2025-01-01 00:00:00'
 AND charging_station_id = 1
GROUP BY charging_date
ORDER BY charging_date
LIMIT 10;


-------------------------------------------------------------------------------------------
-- DEMO 4.1 (Optional) CAGG vs Hypertable - records scaned
-------------------------------------------------------------------------------------------

-- Data Queried CAGG
SELECT COUNT(*) AS total_points
FROM (
   SELECT
       day
   FROM charging_summary_daily
   WHERE charging_station_id = 1
   AND day >= '2023-01-01 00:00:00'
   AND day < '2025-01-01 00:00:00'
   GROUP BY day
) AS subquery;


-- Data Queried Hypertable
SELECT
   COUNT(*) AS total_record_count
FROM ev_charger_telemetry
WHERE measurement_timestamp >= '2023-01-01 00:00:00'
   AND measurement_timestamp < '2025-01-01 00:00:00' 
   AND charging_station_id = 1;


-------------------------------------------------------------------------------------------
-- DEMO 5 Geospatial, Reference and Time-Series Data
--
-- Combine geospatial and time-series data to analyze EV charging station faults
-- near O'Hare Airport in Chicago for the month of January 2024
-- This query counts the number of charging sessions with faults
-- for charging stations within 15 miles of O'Hare Airport
-- and groups the results by week.
-- The query uses PostGIS for geospatial functions and TimescaleDB for time-series data.
-------------------------------------------------------------------------------------------
WITH airport AS (
  -- Define O'Hare Airport location (coordinates: 41.9742° N, 87.9073° W)
  SELECT ST_SetSRID(ST_MakePoint(-87.9073, 41.9742), 4326) AS location_geom
), 
charging_stations_near_airport AS (
    -- Filter charging stations within 15 miles of O'Hare Airport
    SELECT 
      id as charging_station_id
    FROM ev_charging_stations
    CROSS JOIN airport
    WHERE ST_DWithin(
        geom::geography,
        airport.location_geom::geography,
        15 * 1609.34  -- Converting 15 miles to meters
    )
)
SELECT
    -- count the weekly number of charging sessions with faults in January 2024
    -- for charging stations near O'Hare Airport 
    time_bucket('1 week', measurement_timestamp) AS week,
    COUNT(DISTINCT charging_session_id) AS sessions_with_faults,
    station_name
FROM ev_charger_telemetry
-- JOIN with metadata to get station names
JOIN ev_charging_stations ON ev_charger_telemetry.charging_station_id = ev_charging_stations.id
WHERE measurement_timestamp BETWEEN '2024-01-01' AND '2024-01-31'
    AND charger_status = 'fault'
    AND charging_station_id IN (SELECT charging_station_id FROM charging_stations_near_airport)
GROUP BY week, charger_status, station_name
ORDER BY week;


