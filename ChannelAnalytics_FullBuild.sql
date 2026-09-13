/*==============================================================================
  ChannelAnalytics_FullBuild.sql
  ALL-IN-ONE build script. Open in SSMS and press F5 once.

  Builds a distributor channel analytics model for a consumer electronics
  brand selling through Philippine distributors and dealers, then loads one
  year of synthetic data (2025-10-01 to 2026-09-30) and validates it.

  What it produces
      dbo.Numbers             200,000 rows  (tally + deterministic randoms)
      dbo.DimDate                 365 rows
      dbo.DimProduct               24 rows
      dbo.DimDistributor            4 rows
      dbo.DimDealer               150 rows
      dbo.FactSellOut         ~134,785 rows (one row per device sold)
      dbo.FactInventory        ~66,269 rows (one row per device in stock)
      6 reporting views (dbo.vw_*)

  Runtime: a few minutes. The bulk of it is FactSellOut.

  Safe to re-run: it drops and rebuilds its own objects, and creates a separate
  ChannelAnalytics database so nothing in your other databases is touched.

  Watching progress: each section ends with a PRINT. Check the Messages tab to
  see how far it got. The sections run in order and each depends on the one
  before it, so if a section fails, fix that before reading later output.

  SECTIONS
      1  Database and tables
      2  Dimensions
      3  Sell-out fact
      4  Inventory fact
      5  Analysis views
      6  Validation - 12 checks, all should say PASS
==============================================================================*/


/*########## SECTION 1 of 6 : 01_create_database_and_tables.sql ##########*/

/*==============================================================================
  01_create_database_and_tables.sql

  ChannelAnalytics — a distributor channel analytics model for a consumer
  electronics brand selling through Philippine distributors and dealers.

  Grain note: sell-out and inventory are recorded per device (one row = one
  IMEI = one unit), which is how channel management systems in this industry
  actually export data.

  Creates a separate database so nothing in SalesAnalytics is affected.
  Run order: 01 -> 02 -> 03 -> 04 -> 05 -> 06.
==============================================================================*/

IF DB_ID('ChannelAnalytics') IS NULL
    CREATE DATABASE [ChannelAnalytics];
GO

USE [ChannelAnalytics];
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/*--------------------------------------------- drop in dependency order ----*/
DROP VIEW IF EXISTS [dbo].[vw_DealerScorecard];
DROP VIEW IF EXISTS [dbo].[vw_ChannelCoverage];
DROP VIEW IF EXISTS [dbo].[vw_InventoryAging];
DROP VIEW IF EXISTS [dbo].[vw_ProductPerformance];
DROP VIEW IF EXISTS [dbo].[vw_MonthlySellOut];
DROP VIEW IF EXISTS [dbo].[vw_SellOutDetail];
GO
DROP TABLE IF EXISTS [dbo].[FactInventory];
DROP TABLE IF EXISTS [dbo].[FactSellOut];
DROP TABLE IF EXISTS [dbo].[StagingDailyPlan];
DROP TABLE IF EXISTS [dbo].[DimDealer];
DROP TABLE IF EXISTS [dbo].[DimDistributor];
DROP TABLE IF EXISTS [dbo].[DimProduct];
DROP TABLE IF EXISTS [dbo].[DimDate];
DROP TABLE IF EXISTS [dbo].[Numbers];
GO

/*==============================================================================
  dbo.Numbers
  A numbers (tally) table with pre-computed pseudo-random columns.

  R1..R6 are deterministic fractions in [0,1): each is (N * prime + offset)
  modulo a DIFFERENT prime, divided by that prime. Same N always gives the same
  values, so the dataset rebuilds identically every run.

  The differing moduli matter. An earlier version used modulus 10000 for all
  six columns; their pairwise correlation was 0.0000, which looked fine, but
  every column was then a fixed function of the others, and each product ended
  up shipping to only 10 of the 150 dealers. Distinct prime moduli break that
  lock-in — each product now reaches 120+ dealers. Inspect the columns with a
  plain SELECT * FROM dbo.Numbers; nothing is hidden inside a function.
==============================================================================*/
CREATE TABLE [dbo].[Numbers](
    [N]  [int] NOT NULL,
    [R1] [decimal](9,6) NOT NULL,
    [R2] [decimal](9,6) NOT NULL,
    [R3] [decimal](9,6) NOT NULL,
    [R4] [decimal](9,6) NOT NULL,
    [R5] [decimal](9,6) NOT NULL,
    [R6] [decimal](9,6) NOT NULL,
 CONSTRAINT [PK_Numbers] PRIMARY KEY CLUSTERED ([N] ASC)
) ON [PRIMARY];
GO

/*==============================================================================
  dbo.DimDate
==============================================================================*/
CREATE TABLE [dbo].[DimDate](
    [DateKey]        [int] NOT NULL,          -- yyyymmdd
    [FullDate]       [date] NOT NULL,
    [CalendarYear]   [smallint] NOT NULL,
    [CalendarQuarter][tinyint] NOT NULL,
    [MonthNumber]    [tinyint] NOT NULL,
    [MonthName]      [nvarchar](12) NOT NULL,
    [YearMonth]      [int] NOT NULL,          -- yyyymm
    [MonthStartDate] [date] NOT NULL,
    [MonthEndDate]   [date] NOT NULL,
    [DayOfMonth]     [tinyint] NOT NULL,
    [DayName]        [nvarchar](12) NOT NULL,
    [IsWeekend]      [bit] NOT NULL,
    [IsCampaignDay]  [bit] NOT NULL,          -- 6.6, 9.9, 10.10, 11.11, 12.12
    [CampaignName]   [nvarchar](30) NULL,
 CONSTRAINT [PK_DimDate] PRIMARY KEY CLUSTERED ([DateKey] ASC)
) ON [PRIMARY];
GO

CREATE NONCLUSTERED INDEX [IX_DimDate_YearMonth] ON [dbo].[DimDate] ([YearMonth] ASC);
GO

/*==============================================================================
  dbo.DimProduct

  SlotFrom / SlotTo carve the range 1-1000 into shares of demand, so a product
  with 150 slots takes 15% of units. The slots are stored here in the dimension
  rather than computed, so the intended product mix is readable at a glance.

  AgedSlotFrom / AgedSlotTo do the same for stock older than 180 days. They are
  weighted toward end-of-life models, which is what creates the dead-stock
  pattern the analysis is about. NULL means the product holds no aged stock.
==============================================================================*/
CREATE TABLE [dbo].[DimProduct](
    [ProductID]     [nvarchar](20) NOT NULL,  -- item code, e.g. 'EC5 128+4'
    [Model]         [nvarchar](20) NOT NULL,
    [MarketName]    [nvarchar](60) NOT NULL,
    [Series]        [nvarchar](20) NOT NULL,
    [Category]      [nvarchar](20) NOT NULL,
    [Memory]        [nvarchar](15) NOT NULL,
    [PriceTier]     [nvarchar](15) NOT NULL,
    [LifecycleStage][nvarchar](15) NOT NULL,  -- Current / End-of-life
    [SRP]           [decimal](12,2) NOT NULL,
    [DealerPrice]   [decimal](12,2) NOT NULL,
    [SlotFrom]      [int] NOT NULL,
    [SlotTo]        [int] NOT NULL,
    [AgedSlotFrom]  [int] NULL,
    [AgedSlotTo]    [int] NULL,
    [CreatedAt]     [datetime2](7) NOT NULL,
 CONSTRAINT [PK_DimProduct] PRIMARY KEY CLUSTERED ([ProductID] ASC)
) ON [PRIMARY];
GO

ALTER TABLE [dbo].[DimProduct] ADD CONSTRAINT [DF_DimProduct_CreatedAt] DEFAULT (sysdatetime()) FOR [CreatedAt];
GO
ALTER TABLE [dbo].[DimProduct] WITH CHECK ADD CONSTRAINT [CK_DimProduct_Price]
    CHECK ([DealerPrice] > (0) AND [DealerPrice] <= [SRP]);
GO
ALTER TABLE [dbo].[DimProduct] CHECK CONSTRAINT [CK_DimProduct_Price];
GO
ALTER TABLE [dbo].[DimProduct] WITH CHECK ADD CONSTRAINT [CK_DimProduct_Slot]
    CHECK ([SlotFrom] >= (1) AND [SlotTo] <= (1000) AND [SlotFrom] <= [SlotTo]);
GO
ALTER TABLE [dbo].[DimProduct] CHECK CONSTRAINT [CK_DimProduct_Slot];
GO

/*==============================================================================
  dbo.DimDistributor
==============================================================================*/
CREATE TABLE [dbo].[DimDistributor](
    [DistributorID]   [nvarchar](20) NOT NULL,
    [DistributorName] [nvarchar](60) NOT NULL,
    [WarehouseName]   [nvarchar](60) NOT NULL,
    [CoverageArea]    [nvarchar](30) NOT NULL,
    [CreatedAt]       [datetime2](7) NOT NULL,
 CONSTRAINT [PK_DimDistributor] PRIMARY KEY CLUSTERED ([DistributorID] ASC)
) ON [PRIMARY];
GO

ALTER TABLE [dbo].[DimDistributor] ADD CONSTRAINT [DF_DimDistributor_CreatedAt] DEFAULT (sysdatetime()) FOR [CreatedAt];
GO

/*==============================================================================
  dbo.DimDealer

  The real channel export mixes geography and channel into one "region" field
  (values like 'Mindanao' and 'Online' in the same column). This model keeps
  them separate — Region is geography, DealerType is channel — because mixing
  them makes it impossible to answer "how did online do in Mindanao".
==============================================================================*/
CREATE TABLE [dbo].[DimDealer](
    [DealerID]       [nvarchar](20) NOT NULL,
    [DealerName]     [nvarchar](60) NOT NULL,
    [DealerType]     [nvarchar](20) NOT NULL,  -- Retailer / Sub-dealer / Online / Key Account
    [DealerCategory] [nvarchar](30) NOT NULL,  -- IR / KA / NKA / RKA / Online
    [Region]         [nvarchar](30) NOT NULL,
    [City]           [nvarchar](40) NOT NULL,
    [DistributorID]  [nvarchar](20) NOT NULL,
    [SizeTier]       [nchar](1) NOT NULL,      -- A = largest
    [Weight]         [int] NOT NULL,           -- relative share of units
    [SlotFrom]       [int] NOT NULL,           -- carved out of 1-10000
    [SlotTo]         [int] NOT NULL,
    [OnboardDate]    [date] NOT NULL,
    [CreatedAt]      [datetime2](7) NOT NULL,
 CONSTRAINT [PK_DimDealer] PRIMARY KEY CLUSTERED ([DealerID] ASC)
) ON [PRIMARY];
GO

ALTER TABLE [dbo].[DimDealer] ADD CONSTRAINT [DF_DimDealer_CreatedAt] DEFAULT (sysdatetime()) FOR [CreatedAt];
GO
ALTER TABLE [dbo].[DimDealer] WITH CHECK ADD CONSTRAINT [FK_DimDealer_DimDistributor]
    FOREIGN KEY([DistributorID]) REFERENCES [dbo].[DimDistributor] ([DistributorID]);
GO
ALTER TABLE [dbo].[DimDealer] CHECK CONSTRAINT [FK_DimDealer_DimDistributor];
GO

/*==============================================================================
  dbo.StagingDailyPlan
  How many units each day should produce, and where that day's block of rows
  starts in the global sequence. Kept as a table so the demand curve can be
  inspected and charted before any fact rows are generated.
==============================================================================*/
CREATE TABLE [dbo].[StagingDailyPlan](
    [DateKey]     [int] NOT NULL,
    [FullDate]    [date] NOT NULL,
    [UnitsTarget] [int] NOT NULL,
    [SeqStart]    [int] NOT NULL,   -- running total of units before this day
 CONSTRAINT [PK_StagingDailyPlan] PRIMARY KEY CLUSTERED ([DateKey] ASC)
) ON [PRIMARY];
GO

/*==============================================================================
  dbo.FactSellOut
  One row per device sold from a distributor to a dealer.
  SRP and DealerPrice are copied onto the fact so historical rows keep the
  price that applied at the time, even if the price list changes later.
==============================================================================*/
CREATE TABLE [dbo].[FactSellOut](
    [SellOutID]     [int] IDENTITY(1,1) NOT NULL,
    [IMEI]          [nvarchar](20) NOT NULL,
    [DateKey]       [int] NOT NULL,
    [SellOutDate]   [date] NOT NULL,
    [ProductID]     [nvarchar](20) NOT NULL,
    [DistributorID] [nvarchar](20) NOT NULL,
    [DealerID]      [nvarchar](20) NOT NULL,
    [Region]        [nvarchar](30) NOT NULL,
    [DealerType]    [nvarchar](20) NOT NULL,
    [Quantity]      [int] NOT NULL,
    [SRP]           [decimal](12,2) NOT NULL,
    [DealerPrice]   [decimal](12,2) NOT NULL,
    [SRPValue]      [decimal](14,2) NOT NULL,
    [DealerValue]   [decimal](14,2) NOT NULL,
    [CreatedAt]     [datetime2](7) NOT NULL,
 CONSTRAINT [PK_FactSellOut] PRIMARY KEY CLUSTERED ([SellOutID] ASC)
) ON [PRIMARY];
GO

ALTER TABLE [dbo].[FactSellOut] ADD CONSTRAINT [DF_FactSellOut_CreatedAt] DEFAULT (sysdatetime()) FOR [CreatedAt];
GO
ALTER TABLE [dbo].[FactSellOut] WITH CHECK ADD CONSTRAINT [FK_FactSellOut_DimDate]
    FOREIGN KEY([DateKey]) REFERENCES [dbo].[DimDate] ([DateKey]);
GO
ALTER TABLE [dbo].[FactSellOut] CHECK CONSTRAINT [FK_FactSellOut_DimDate];
GO
ALTER TABLE [dbo].[FactSellOut] WITH CHECK ADD CONSTRAINT [FK_FactSellOut_DimProduct]
    FOREIGN KEY([ProductID]) REFERENCES [dbo].[DimProduct] ([ProductID]);
GO
ALTER TABLE [dbo].[FactSellOut] CHECK CONSTRAINT [FK_FactSellOut_DimProduct];
GO
ALTER TABLE [dbo].[FactSellOut] WITH CHECK ADD CONSTRAINT [FK_FactSellOut_DimDealer]
    FOREIGN KEY([DealerID]) REFERENCES [dbo].[DimDealer] ([DealerID]);
GO
ALTER TABLE [dbo].[FactSellOut] CHECK CONSTRAINT [FK_FactSellOut_DimDealer];
GO
ALTER TABLE [dbo].[FactSellOut] WITH CHECK ADD CONSTRAINT [FK_FactSellOut_DimDistributor]
    FOREIGN KEY([DistributorID]) REFERENCES [dbo].[DimDistributor] ([DistributorID]);
GO
ALTER TABLE [dbo].[FactSellOut] CHECK CONSTRAINT [FK_FactSellOut_DimDistributor];
GO
ALTER TABLE [dbo].[FactSellOut] WITH CHECK ADD CONSTRAINT [CK_FactSellOut_Quantity]
    CHECK ([Quantity] > (0));
GO
ALTER TABLE [dbo].[FactSellOut] CHECK CONSTRAINT [CK_FactSellOut_Quantity];
GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_FactSellOut_IMEI] ON [dbo].[FactSellOut] ([IMEI] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_FactSellOut_DateKey] ON [dbo].[FactSellOut] ([DateKey] ASC)
    INCLUDE ([ProductID], [DealerID], [SRPValue]);
GO
CREATE NONCLUSTERED INDEX [IX_FactSellOut_Product] ON [dbo].[FactSellOut] ([ProductID] ASC, [DateKey] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_FactSellOut_Dealer] ON [dbo].[FactSellOut] ([DealerID] ASC, [DateKey] ASC);
GO

/*==============================================================================
  dbo.FactInventory
  Stock still sitting in the channel as at the snapshot date. One row per
  device. InventoryDurationDays is the ageing measure the whole analysis
  hangs on: snapshot date minus receive date.
==============================================================================*/
CREATE TABLE [dbo].[FactInventory](
    [InventoryID]           [int] IDENTITY(1,1) NOT NULL,
    [SnapshotDate]          [date] NOT NULL,
    [IMEI]                  [nvarchar](20) NOT NULL,
    [ProductID]             [nvarchar](20) NOT NULL,
    [DistributorID]         [nvarchar](20) NOT NULL,
    [DealerID]              [nvarchar](20) NOT NULL,
    [Region]                [nvarchar](30) NOT NULL,
    [DealerType]            [nvarchar](20) NOT NULL,
    [ReceiveDate]           [date] NOT NULL,
    [InventoryDurationDays] [int] NOT NULL,
    [StockStatus]           [nvarchar](20) NOT NULL,
    [SRP]                   [decimal](12,2) NOT NULL,
    [DealerPrice]           [decimal](12,2) NOT NULL,
    [CreatedAt]             [datetime2](7) NOT NULL,
 CONSTRAINT [PK_FactInventory] PRIMARY KEY CLUSTERED ([InventoryID] ASC)
) ON [PRIMARY];
GO

ALTER TABLE [dbo].[FactInventory] ADD CONSTRAINT [DF_FactInventory_CreatedAt] DEFAULT (sysdatetime()) FOR [CreatedAt];
GO
ALTER TABLE [dbo].[FactInventory] WITH CHECK ADD CONSTRAINT [FK_FactInventory_DimProduct]
    FOREIGN KEY([ProductID]) REFERENCES [dbo].[DimProduct] ([ProductID]);
GO
ALTER TABLE [dbo].[FactInventory] CHECK CONSTRAINT [FK_FactInventory_DimProduct];
GO
ALTER TABLE [dbo].[FactInventory] WITH CHECK ADD CONSTRAINT [FK_FactInventory_DimDealer]
    FOREIGN KEY([DealerID]) REFERENCES [dbo].[DimDealer] ([DealerID]);
GO
ALTER TABLE [dbo].[FactInventory] CHECK CONSTRAINT [FK_FactInventory_DimDealer];
GO
ALTER TABLE [dbo].[FactInventory] WITH CHECK ADD CONSTRAINT [CK_FactInventory_Duration]
    CHECK ([InventoryDurationDays] >= (0));
GO
ALTER TABLE [dbo].[FactInventory] CHECK CONSTRAINT [CK_FactInventory_Duration];
GO

CREATE UNIQUE NONCLUSTERED INDEX [UX_FactInventory_IMEI] ON [dbo].[FactInventory] ([IMEI] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_FactInventory_Dealer] ON [dbo].[FactInventory] ([DealerID] ASC);
GO
CREATE NONCLUSTERED INDEX [IX_FactInventory_Duration] ON [dbo].[FactInventory] ([InventoryDurationDays] ASC)
    INCLUDE ([ProductID], [DealerPrice]);
GO

PRINT '01 complete - ChannelAnalytics database, 8 tables, constraints and indexes created.';
GO
GO


/*########## SECTION 2 of 6 : 02_seed_dimensions.sql ##########*/

USE [ChannelAnalytics];
GO

/*==============================================================================
  02_seed_dimensions.sql
  Fills the numbers table and all four dimensions.
  Period: 2025-10-01 to 2026-09-30 (12 months).
==============================================================================*/


SET NOCOUNT ON;

DECLARE @StartDate date = '2025-10-01';
DECLARE @EndDate   date = '2026-09-30';

/*----------------------------------------------------------- cleanup -------*/
DELETE FROM [dbo].[FactInventory];
DELETE FROM [dbo].[FactSellOut];
DELETE FROM [dbo].[StagingDailyPlan];
DELETE FROM [dbo].[DimDealer];
DELETE FROM [dbo].[DimDistributor];
DELETE FROM [dbo].[DimProduct];
DELETE FROM [dbo].[DimDate];
DELETE FROM [dbo].[Numbers];

/*==============================================================================
  dbo.Numbers — 200,000 rows with six deterministic pseudo-random columns.
  Built by cross-joining a 10-row list five times (10^5 = 100,000) twice over.
==============================================================================*/
;WITH Ten AS (
    SELECT n FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) AS t(n)
),
Rows200k AS (
    SELECT TOP (200000)
           ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
    FROM Ten a CROSS JOIN Ten b CROSS JOIN Ten c
         CROSS JOIN Ten d CROSS JOIN Ten e CROSS JOIN Ten f
)
INSERT INTO [dbo].[Numbers] ([N],[R1],[R2],[R3],[R4],[R5],[R6])
SELECT
    N,
    /* each column uses a different prime modulus - see the note on dbo.Numbers */
    CAST((CAST(N AS bigint) *  7919 + 1223) % 9973 AS decimal(18,6)) / 9973,
    CAST((CAST(N AS bigint) * 15013 + 3527) % 9967 AS decimal(18,6)) / 9967,
    CAST((CAST(N AS bigint) * 22447 + 6091) % 9949 AS decimal(18,6)) / 9949,
    CAST((CAST(N AS bigint) * 31543 + 8419) % 9941 AS decimal(18,6)) / 9941,
    CAST((CAST(N AS bigint) * 45677 + 2749) % 9931 AS decimal(18,6)) / 9931,
    CAST((CAST(N AS bigint) * 57193 + 9377) % 9929 AS decimal(18,6)) / 9929
FROM Rows200k;

/*==============================================================================
  dbo.DimDate
==============================================================================*/
INSERT INTO [dbo].[DimDate]
    ([DateKey],[FullDate],[CalendarYear],[CalendarQuarter],[MonthNumber],[MonthName],
     [YearMonth],[MonthStartDate],[MonthEndDate],[DayOfMonth],[DayName],
     [IsWeekend],[IsCampaignDay],[CampaignName])
SELECT
    YEAR(d.FullDate) * 10000 + MONTH(d.FullDate) * 100 + DAY(d.FullDate),
    d.FullDate,
    YEAR(d.FullDate),
    DATEPART(QUARTER, d.FullDate),
    MONTH(d.FullDate),
    DATENAME(MONTH, d.FullDate),
    YEAR(d.FullDate) * 100 + MONTH(d.FullDate),
    DATEFROMPARTS(YEAR(d.FullDate), MONTH(d.FullDate), 1),
    EOMONTH(d.FullDate),
    DAY(d.FullDate),
    DATENAME(WEEKDAY, d.FullDate),
    CASE WHEN DATENAME(WEEKDAY, d.FullDate) IN ('Saturday','Sunday') THEN 1 ELSE 0 END,
    CASE WHEN DAY(d.FullDate) = MONTH(d.FullDate)
              AND MONTH(d.FullDate) IN (6,9,10,11,12) THEN 1 ELSE 0 END,
    CASE WHEN DAY(d.FullDate) = MONTH(d.FullDate) AND MONTH(d.FullDate) IN (6,9,10,11,12)
         THEN CONCAT(MONTH(d.FullDate), '.', MONTH(d.FullDate), ' Sale') END
FROM (
    SELECT DATEADD(DAY, n.N - 1, @StartDate) AS FullDate
    FROM [dbo].[Numbers] AS n
    WHERE n.N <= DATEDIFF(DAY, @StartDate, @EndDate) + 1
) AS d;

/*==============================================================================
  dbo.DimProduct
  24 SKUs across 5 series. Slot shares mirror a real Philippine channel mix:
  entry ~66%, mid ~15%, performance ~12%, tablet ~6%, premium ~1%.
  Aged slots are weighted to end-of-life models — that is what produces the
  dead-stock concentration the analysis is about.
==============================================================================*/
INSERT INTO [dbo].[DimProduct]
    ([ProductID],[Model],[MarketName],[Series],[Category],[Memory],[PriceTier],
     [LifecycleStage],[SRP],[DealerPrice],[SlotFrom],[SlotTo],[AgedSlotFrom],[AgedSlotTo])
VALUES
 -- ECHO series (entry) — 665 of 1000 slots
 ('EC5 64+4',    'EC5','NOVEX ECHO 5',        'ECHO','Mobile','64+4',   'Entry',  'Current',      4999.00, 4499.00,   1, 120,    1,  50),
 ('EC5 128+4',   'EC5','NOVEX ECHO 5',        'ECHO','Mobile','128+4',  'Entry',  'Current',      5799.00, 5219.00, 121, 270, NULL,NULL),
 ('EC5 128+6',   'EC5','NOVEX ECHO 5',        'ECHO','Mobile','128+6',  'Entry',  'Current',      6499.00, 5849.00, 271, 360,   51,  80),
 ('EC7 128+4',   'EC7','NOVEX ECHO 7',        'ECHO','Mobile','128+4',  'Entry',  'Current',      6999.00, 6299.00, 361, 470, NULL,NULL),
 ('EC7 256+8',   'EC7','NOVEX ECHO 7',        'ECHO','Mobile','256+8',  'Entry',  'Current',      8499.00, 7649.00, 471, 555, NULL,NULL),
 ('EC7G 128+6',  'EC7G','NOVEX ECHO 7 5G',    'ECHO','Mobile','128+6',  'Entry',  'Current',      9999.00, 8999.00, 556, 615, NULL,NULL),
 ('EC3 64+4',    'EC3','NOVEX ECHO 3',        'ECHO','Mobile','64+4',   'Entry',  'End-of-life',  4299.00, 3869.00, 616, 645,   81, 300),
 ('EC3 128+4',   'EC3','NOVEX ECHO 3',        'ECHO','Mobile','128+4',  'Entry',  'End-of-life',  4799.00, 4319.00, 646, 665,  301, 480),
 -- LUMEN series (mid) — 151 slots
 ('LM5 128+8',   'LM5','NOVEX LUMEN 5',       'LUMEN','Mobile','128+8', 'Mid',    'Current',     13999.00,12599.00, 666, 710, NULL,NULL),
 ('LM5 256+8',   'LM5','NOVEX LUMEN 5',       'LUMEN','Mobile','256+8', 'Mid',    'Current',     15499.00,13949.00, 711, 750, NULL,NULL),
 ('LM7 256+8',   'LM7','NOVEX LUMEN 7 5G',    'LUMEN','Mobile','256+8', 'Mid',    'Current',     19999.00,17999.00, 751, 780, NULL,NULL),
 ('LM7 512+12',  'LM7','NOVEX LUMEN 7 5G',    'LUMEN','Mobile','512+12','Premium','Current',     24999.00,22499.00, 781, 800,  481, 510),
 ('LM3 128+6',   'LM3','NOVEX LUMEN 3',       'LUMEN','Mobile','128+6', 'Mid',    'End-of-life', 11999.00,10799.00, 801, 816,  511, 640),
 -- SURGE series (performance) — 117 slots
 ('SG6 128+8',   'SG6','NOVEX SURGE 6',       'SURGE','Mobile','128+8', 'Mid',    'Current',     10999.00, 9899.00, 817, 856, NULL,NULL),
 ('SG6 256+8',   'SG6','NOVEX SURGE 6',       'SURGE','Mobile','256+8', 'Mid',    'Current',     12499.00,11249.00, 857, 891, NULL,NULL),
 ('SG8 256+12',  'SG8','NOVEX SURGE 8 5G',    'SURGE','Mobile','256+12','Premium','Current',     16999.00,15299.00, 892, 918, NULL,NULL),
 ('SG4 128+6',   'SG4','NOVEX SURGE 4',       'SURGE','Mobile','128+6', 'Mid',    'End-of-life',  9499.00, 8549.00, 919, 933,  641, 760),
 -- SLATE series (tablets) — 62 slots
 ('SL2 128+4',   'SL2','NOVEX SLATE 2',       'SLATE','Tablet','128+4', 'Entry',  'Current',      8999.00, 8099.00, 934, 957, NULL,NULL),
 ('SL2 256+8',   'SL2','NOVEX SLATE 2',       'SLATE','Tablet','256+8', 'Mid',    'Current',     11499.00,10349.00, 958, 975, NULL,NULL),
 ('SLP 256+8',   'SLP','NOVEX SLATE Pro',     'SLATE','Tablet','256+8', 'Mid',    'Current',     15999.00,14399.00, 976, 987,  761, 790),
 ('SLS 64+4',    'SLS','NOVEX SLATE SE',      'SLATE','Tablet','64+4',  'Entry',  'End-of-life',  6499.00, 5849.00, 988, 995,  791, 880),
 -- APEX series (premium) — 5 slots
 ('AP2 256+12',  'AP2','NOVEX APEX 2 5G',     'APEX','Mobile','256+12', 'Premium','Current',     39999.00,35999.00, 996, 997,  881, 930),
 ('AP2 512+12',  'AP2','NOVEX APEX 2 5G',     'APEX','Mobile','512+12', 'Premium','Current',     47999.00,43199.00, 998, 999,  931, 970),
 ('APF 512+12',  'APF','NOVEX APEX Fold 5G',  'APEX','Mobile','512+12', 'Premium','End-of-life', 59999.00,53999.00,1000,1000,  971,1000);

/*==============================================================================
  dbo.DimDistributor
==============================================================================*/
INSERT INTO [dbo].[DimDistributor]
    ([DistributorID],[DistributorName],[WarehouseName],[CoverageArea])
VALUES
 ('DST-01','Northgate Mobile Distribution','WH Northgate Quezon City','Luzon'),
 ('DST-02','Sierra Telecom Supply',        'WH Sierra Pasig',         'NCR and Online'),
 ('DST-03','Visayan Link Trading',         'WH Visayan Link Cebu',    'Visayas'),
 ('DST-04','Southpoint Device Distribution','WH Southpoint Davao',    'Mindanao');

/*==============================================================================
  dbo.DimDealer — 150 dealers.

  Size tiers concentrate volume the way a real channel does: 10 large accounts
  take 45% of units, 30 mid accounts 35%, and 110 long-tail accounts the
  remaining 20%. The weights are set so they total exactly 10000 
  (10*448 + 30*118 + 110*18), which means every possible random draw lands on
  a dealer and no rows are silently lost in the join.

  SlotFrom / SlotTo are carved out of 1-10000 with a running total. SUM() OVER
  with ROWS UNBOUNDED PRECEDING gives each dealer a cumulative range, so a
  single random number between 1 and 10000 picks a dealer in proportion to its
  weight.
==============================================================================*/
;WITH DealerBase AS (
    SELECT
        n.N,
        CONCAT('DLR-', RIGHT('000' + CAST(n.N AS varchar(3)), 3)) AS DealerID,
        CASE WHEN n.N <= 10 THEN 'A' WHEN n.N <= 40 THEN 'B' ELSE 'C' END AS SizeTier,
        CASE WHEN n.N <= 10 THEN 448 WHEN n.N <= 40 THEN 118 ELSE 18 END AS Weight,
        CASE WHEN n.R1 < 0.2600 THEN 'NCR'
             WHEN n.R1 < 0.4200 THEN 'Mindanao'
             WHEN n.R1 < 0.5600 THEN 'Visayas'
             WHEN n.R1 < 0.6900 THEN 'South Luzon'
             WHEN n.R1 < 0.8000 THEN 'North Luzon'
             WHEN n.R1 < 0.9000 THEN 'Central Luzon'
             ELSE 'Bicol and Mimaropa' END AS Region,
        CASE WHEN n.R2 < 0.2800 THEN 'Online'
             WHEN n.R2 < 0.4000 THEN 'Key Account'
             WHEN n.R2 < 0.7200 THEN 'Retailer'
             ELSE 'Sub-dealer' END AS DealerType,
        n.R3, n.R4
    FROM [dbo].[Numbers] AS n
    WHERE n.N <= 150
),
DealerRanged AS (
    SELECT *,
           SUM(Weight) OVER (ORDER BY N ROWS UNBOUNDED PRECEDING) AS RunningTotal
    FROM DealerBase
)
INSERT INTO [dbo].[DimDealer]
    ([DealerID],[DealerName],[DealerType],[DealerCategory],[Region],[City],
     [DistributorID],[SizeTier],[Weight],[SlotFrom],[SlotTo],[OnboardDate])
SELECT
    d.DealerID,
    CONCAT('Dealer ', RIGHT('000' + CAST(d.N AS varchar(3)), 3), ' ',
           CASE d.DealerType WHEN 'Online' THEN 'Online Store'
                             WHEN 'Key Account' THEN 'Retail Group'
                             WHEN 'Retailer' THEN 'Mobile Center'
                             ELSE 'Trading' END),
    d.DealerType,
    CASE d.DealerType
         WHEN 'Online'      THEN 'Online'
         WHEN 'Key Account' THEN CASE WHEN d.SizeTier = 'A' THEN 'NKA (National Key Account)'
                                      ELSE 'RKA (Regional Key Account)' END
         WHEN 'Retailer'    THEN 'IR (Independent Retailer)'
         ELSE 'SD (Sub-dealer)' END,
    d.Region,
    CASE d.Region
         WHEN 'NCR'                THEN CASE WHEN d.R3 < 0.34 THEN 'Quezon City' WHEN d.R3 < 0.67 THEN 'Manila' ELSE 'Pasig' END
         WHEN 'Mindanao'           THEN CASE WHEN d.R3 < 0.40 THEN 'Davao' WHEN d.R3 < 0.75 THEN 'Cagayan de Oro' ELSE 'General Santos' END
         WHEN 'Visayas'            THEN CASE WHEN d.R3 < 0.50 THEN 'Cebu' WHEN d.R3 < 0.80 THEN 'Iloilo' ELSE 'Bacolod' END
         WHEN 'South Luzon'        THEN CASE WHEN d.R3 < 0.50 THEN 'Calamba' ELSE 'Batangas' END
         WHEN 'North Luzon'        THEN CASE WHEN d.R3 < 0.50 THEN 'Baguio' ELSE 'Dagupan' END
         WHEN 'Central Luzon'      THEN CASE WHEN d.R3 < 0.50 THEN 'Angeles' ELSE 'Cabanatuan' END
         ELSE                           CASE WHEN d.R3 < 0.50 THEN 'Naga' ELSE 'Puerto Princesa' END END,
    CASE WHEN d.Region IN ('NCR')                        THEN 'DST-02'
         WHEN d.Region IN ('North Luzon','Central Luzon','South Luzon','Bicol and Mimaropa') THEN 'DST-01'
         WHEN d.Region = 'Visayas'                       THEN 'DST-03'
         ELSE 'DST-04' END,
    d.SizeTier,
    d.Weight,
    d.RunningTotal - d.Weight + 1,
    d.RunningTotal,
    DATEADD(DAY, -CAST(d.R4 * 1200 AS int), '2025-10-01')
FROM DealerRanged AS d;

PRINT '02 complete.';
SELECT 'Numbers' AS TableName, COUNT(*) AS [RowCount] FROM [dbo].[Numbers]
UNION ALL SELECT 'DimDate',        COUNT(*) FROM [dbo].[DimDate]
UNION ALL SELECT 'DimProduct',     COUNT(*) FROM [dbo].[DimProduct]
UNION ALL SELECT 'DimDistributor', COUNT(*) FROM [dbo].[DimDistributor]
UNION ALL SELECT 'DimDealer',      COUNT(*) FROM [dbo].[DimDealer];
GO
GO


/*########## SECTION 3 of 6 : 03_seed_factsellout.sql ##########*/

USE [ChannelAnalytics];
GO

/*==============================================================================
  03_seed_factsellout.sql
  Generates one year of device-level sell-out (~134,800 rows).

  Two steps, both set-based:
    1. StagingDailyPlan  — how many units each day, and where that day's block
                           starts in the global sequence.
    2. FactSellOut       — join the plan to dbo.Numbers to explode each day
                           into its rows, then use the pre-computed random
                           columns to pick a product and a dealer.

  Daily units = 330 base
              x month seasonality      (Q4 peak, January trough)
              x day-of-week factor
              x campaign-day spike     (6.6 / 9.9 / 10.10 / 11.11 / 12.12)
              x growth trend           (+18% across the year)
==============================================================================*/


SET NOCOUNT ON;

DELETE FROM [dbo].[FactSellOut];
DELETE FROM [dbo].[StagingDailyPlan];
DBCC CHECKIDENT ('dbo.FactSellOut', RESEED, 0) WITH NO_INFOMSGS;

/*------------------------------------------------ step 1: the daily plan ---*/
;WITH DailyTarget AS (
    SELECT
        d.DateKey,
        d.FullDate,
        CONVERT(int, ROUND(
              330.0
            * CASE d.MonthNumber
                   WHEN  1 THEN 0.72 WHEN  2 THEN 0.78 WHEN  3 THEN 0.92
                   WHEN  4 THEN 0.88 WHEN  5 THEN 0.95 WHEN  6 THEN 1.12
                   WHEN  7 THEN 0.95 WHEN  8 THEN 1.00 WHEN  9 THEN 1.05
                   WHEN 10 THEN 1.05 WHEN 11 THEN 1.55 ELSE 1.35 END
            * CASE d.DayName WHEN 'Saturday' THEN 0.90
                             WHEN 'Sunday'   THEN 0.85
                             WHEN 'Friday'   THEN 1.05
                             ELSE 1.00 END
            * CASE WHEN d.IsCampaignDay = 1 THEN 2.60
                   WHEN d.MonthNumber IN (11,12)
                        /* CAST to int first: tinyint minus tinyint stays tinyint
                           in SQL Server, and tinyint cannot hold a negative
                           value, so day 1 minus month 12 overflows before ABS
                           ever sees it (Msg 8115). */
                        AND ABS(CAST(d.DayOfMonth AS int) - CAST(d.MonthNumber AS int)) = 1
                            THEN 1.40
                   ELSE 1.00 END
            * (1.0 + 0.18 * DATEDIFF(MONTH, '2025-10-01', d.FullDate) / 11.0)
        , 0)) AS UnitsTarget
    FROM [dbo].[DimDate] AS d
)
INSERT INTO [dbo].[StagingDailyPlan] ([DateKey],[FullDate],[UnitsTarget],[SeqStart])
SELECT
    DateKey,
    FullDate,
    UnitsTarget,
    /* running total of all earlier days, so every row in the year gets a
       unique sequence number and therefore a unique IMEI */
    ISNULL(SUM(UnitsTarget) OVER (ORDER BY DateKey
                                  ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
FROM DailyTarget;

DECLARE @PlannedUnits int;
SELECT @PlannedUnits = SUM([UnitsTarget]) FROM [dbo].[StagingDailyPlan];
PRINT CONCAT('Planned units for the year: ', @PlannedUnits);

/*------------------------------------------- step 2: explode into devices --*/
/* n  = position within the day (1..UnitsTarget)
   g  = the same row's position in the whole year; its R columns drive the
        product and dealer picks, so the choices differ every day          */
;WITH DeviceRow AS (
    SELECT
        p.DateKey,
        p.FullDate,
        p.SeqStart + n.N AS GlobalSeq,
        g.R1, g.R2
    FROM [dbo].[StagingDailyPlan] AS p
    INNER JOIN [dbo].[Numbers] AS n
            ON n.N <= p.UnitsTarget
    INNER JOIN [dbo].[Numbers] AS g
            ON g.N = p.SeqStart + n.N
)
INSERT INTO [dbo].[FactSellOut]
    ([IMEI],[DateKey],[SellOutDate],[ProductID],[DistributorID],[DealerID],
     [Region],[DealerType],[Quantity],[SRP],[DealerPrice],[SRPValue],[DealerValue])
SELECT
    /* 15-digit IMEI: fixed 6-digit type allocation prefix + sequence */
    CONCAT('351842', RIGHT('000000000' + CAST(100000 + r.GlobalSeq AS varchar(9)), 9)),
    r.DateKey,
    r.FullDate,
    pr.ProductID,
    dl.DistributorID,
    dl.DealerID,
    dl.Region,
    dl.DealerType,
    1,
    pr.SRP,
    pr.DealerPrice,
    pr.SRP,
    pr.DealerPrice
FROM DeviceRow AS r
/* R1 x 1000 lands inside exactly one product's slot range */
INNER JOIN [dbo].[DimProduct] AS pr
        ON CONVERT(int, r.R1 * 1000) + 1 BETWEEN pr.SlotFrom AND pr.SlotTo
/* R2 x 10000 lands inside exactly one dealer's slot range */
INNER JOIN [dbo].[DimDealer] AS dl
        ON CONVERT(int, r.R2 * 10000) + 1 BETWEEN dl.SlotFrom AND dl.SlotTo;

DECLARE @SellOutRows int;
SELECT @SellOutRows = COUNT(*) FROM [dbo].[FactSellOut];
PRINT CONCAT('FactSellOut rows inserted: ', @SellOutRows);
PRINT '03 complete.';
GO
GO


/*########## SECTION 4 of 6 : 04_seed_factinventory.sql ##########*/

USE [ChannelAnalytics];
GO

/*==============================================================================
  04_seed_factinventory.sql
  Builds the channel inventory snapshot as at 2026-09-30 — stock that has been
  shipped to dealers but not yet sold to consumers. One row per device.

  The unit count is derived from actual sell-out (5.9 months of cover) rather
  than hard-coded, so if you change the sell-out volume the inventory scales
  with it and the coverage ratio stays honest.

  Ageing mix (R3 decides the bucket):
      under 30 days   28.7%      180-365 days    1.8%
      30-90 days      37.2%      over 365 days   1.4%
      90-180 days     31.0%

  Stock over 180 days is drawn from the AgedSlot ranges in DimProduct, which
  are weighted toward end-of-life models. That is what makes dead stock
  concentrate in the SKUs you would expect it to, instead of spreading evenly.
==============================================================================*/


SET NOCOUNT ON;

DELETE FROM [dbo].[FactInventory];
DBCC CHECKIDENT ('dbo.FactInventory', RESEED, 0) WITH NO_INFOMSGS;

DECLARE @SnapshotDate date = '2026-09-30';
DECLARE @MonthsOfCover decimal(4,1) = 5.9;
DECLARE @InventoryUnits int;

SELECT @InventoryUnits = CONVERT(int, ROUND(COUNT(*) / 12.0 * @MonthsOfCover, 0))
FROM [dbo].[FactSellOut];

PRINT CONCAT('Generating ', @InventoryUnits, ' inventory units at ',
             @MonthsOfCover, ' months of cover.');

;WITH DeviceRow AS (
    SELECT
        n.N AS Seq,
        n.R1, n.R2, n.R3, n.R4, n.R5
    FROM [dbo].[Numbers] AS n
    WHERE n.N <= @InventoryUnits
),
Aged AS (
    SELECT
        d.*,
        /* bucket boundaries are cumulative shares of R3 */
        CASE WHEN d.R3 < 0.287 THEN CONVERT(int,  0 + d.R4 *  30)
             WHEN d.R3 < 0.659 THEN CONVERT(int, 30 + d.R4 *  60)
             WHEN d.R3 < 0.969 THEN CONVERT(int, 90 + d.R4 *  90)
             WHEN d.R3 < 0.987 THEN CONVERT(int,180 + d.R4 * 185)
             ELSE                   CONVERT(int,365 + d.R4 * 900)
        END AS DurationDays
    FROM DeviceRow AS d
)
INSERT INTO [dbo].[FactInventory]
    ([SnapshotDate],[IMEI],[ProductID],[DistributorID],[DealerID],[Region],
     [DealerType],[ReceiveDate],[InventoryDurationDays],[StockStatus],[SRP],[DealerPrice])
SELECT
    @SnapshotDate,
    /* different IMEI block from sell-out so the two never collide */
    CONCAT('351842', RIGHT('000000000' + CAST(500000 + a.Seq AS varchar(9)), 9)),
    pr.ProductID,
    dl.DistributorID,
    dl.DealerID,
    dl.Region,
    dl.DealerType,
    DATEADD(DAY, -a.DurationDays, @SnapshotDate),
    a.DurationDays,
    CASE WHEN a.R5 < 0.0015 THEN 'Blocked' ELSE 'Available' END,
    pr.SRP,
    pr.DealerPrice
FROM Aged AS a
INNER JOIN [dbo].[DimDealer] AS dl
        ON CONVERT(int, a.R2 * 10000) + 1 BETWEEN dl.SlotFrom AND dl.SlotTo
/* fresh stock follows the normal sales mix; stock over 180 days follows the
   aged mix, which is weighted to end-of-life models */
INNER JOIN [dbo].[DimProduct] AS pr
        ON (a.DurationDays <  180 AND CONVERT(int, a.R1 * 1000) + 1 BETWEEN pr.SlotFrom AND pr.SlotTo)
        OR (a.DurationDays >= 180 AND CONVERT(int, a.R5 * 1000) + 1 BETWEEN pr.AgedSlotFrom AND pr.AgedSlotTo);

DECLARE @InventoryRows int;
SELECT @InventoryRows = COUNT(*) FROM [dbo].[FactInventory];
PRINT CONCAT('FactInventory rows inserted: ', @InventoryRows);
PRINT '04 complete.';
GO
GO


/*########## SECTION 5 of 6 : 05_analysis_views.sql ##########*/

USE [ChannelAnalytics];
GO

/*==============================================================================
  05_analysis_views.sql
  The reporting layer. Power BI connects to these views, not to the tables, so
  a measure like "dead stock" is defined once in SQL and cannot drift between
  Power BI, Excel and an ad-hoc query.

    vw_SellOutDetail      one row per device sold, all dimensions joined
    vw_MonthlySellOut     month           - units, value, month-on-month
    vw_ProductPerformance month x product - rank, share of month
    vw_InventoryAging     one row per device in stock, with its age bucket
    vw_ChannelCoverage    product         - months of cover, over/under stocked
    vw_DealerScorecard    dealer          - sell-out vs stock held vs dead stock
==============================================================================*/


/*==============================================================================
  vw_SellOutDetail
==============================================================================*/
CREATE OR ALTER VIEW [dbo].[vw_SellOutDetail]
AS
SELECT
    f.[SellOutID],
    f.[IMEI],
    f.[SellOutDate],
    d.[YearMonth],
    d.[MonthStartDate],
    d.[CalendarYear],
    d.[CalendarQuarter],
    d.[MonthName],
    d.[IsWeekend],
    d.[IsCampaignDay],
    d.[CampaignName],
    f.[ProductID],
    p.[MarketName],
    p.[Series],
    p.[Category],
    p.[Memory],
    p.[PriceTier],
    p.[LifecycleStage],
    f.[DealerID],
    dl.[DealerName],
    dl.[DealerType],
    dl.[DealerCategory],
    dl.[SizeTier],
    f.[Region],
    dl.[City],
    f.[DistributorID],
    dist.[DistributorName],
    f.[Quantity],
    f.[SRP],
    f.[DealerPrice],
    f.[SRPValue],
    f.[DealerValue],
    f.[SRPValue] - f.[DealerValue] AS [DealerMarginValue]
FROM [dbo].[FactSellOut] AS f
INNER JOIN [dbo].[DimDate]        AS d    ON d.[DateKey]       = f.[DateKey]
INNER JOIN [dbo].[DimProduct]     AS p    ON p.[ProductID]     = f.[ProductID]
INNER JOIN [dbo].[DimDealer]      AS dl   ON dl.[DealerID]     = f.[DealerID]
INNER JOIN [dbo].[DimDistributor] AS dist ON dist.[DistributorID] = f.[DistributorID];
GO

/*==============================================================================
  vw_MonthlySellOut
  LAG() reads the previous row in the ordered result, which is how the
  month-on-month comparison is done without joining the table to itself.
==============================================================================*/
CREATE OR ALTER VIEW [dbo].[vw_MonthlySellOut]
AS
WITH MonthTotals AS (
    SELECT
        [YearMonth],
        MIN([MonthStartDate])   AS [MonthStartDate],
        SUM([Quantity])         AS [UnitsSold],
        SUM([SRPValue])         AS [SRPValue],
        SUM([DealerValue])      AS [DealerValue],
        COUNT(DISTINCT [DealerID])  AS [ActiveDealers],
        COUNT(DISTINCT [ProductID]) AS [ActiveSKUs]
    FROM [dbo].[vw_SellOutDetail]
    GROUP BY [YearMonth]
)
SELECT
    m.[YearMonth],
    m.[MonthStartDate],
    m.[UnitsSold],
    m.[SRPValue],
    m.[DealerValue],
    m.[ActiveDealers],
    m.[ActiveSKUs],
    CAST(m.[SRPValue] / NULLIF(m.[UnitsSold], 0) AS decimal(12,2)) AS [AvgSellingPrice],
    LAG(m.[UnitsSold]) OVER (ORDER BY m.[YearMonth])               AS [PrevMonthUnits],
    CAST(1.0 * m.[UnitsSold]
         / NULLIF(LAG(m.[UnitsSold]) OVER (ORDER BY m.[YearMonth]), 0) - 1
         AS decimal(8,4))                                          AS [MoMGrowth]
FROM MonthTotals AS m;
GO

/*==============================================================================
  vw_ProductPerformance
==============================================================================*/
CREATE OR ALTER VIEW [dbo].[vw_ProductPerformance]
AS
WITH ProductMonth AS (
    SELECT
        [YearMonth],
        [MonthStartDate],
        [ProductID],
        [MarketName],
        [Series],
        [PriceTier],
        [LifecycleStage],
        SUM([Quantity])            AS [UnitsSold],
        SUM([SRPValue])            AS [SRPValue],
        COUNT(DISTINCT [DealerID]) AS [DealersBuying]
    FROM [dbo].[vw_SellOutDetail]
    GROUP BY [YearMonth], [MonthStartDate], [ProductID], [MarketName],
             [Series], [PriceTier], [LifecycleStage]
)
SELECT
    pm.*,
    RANK() OVER (PARTITION BY pm.[YearMonth] ORDER BY pm.[SRPValue] DESC) AS [RankInMonth],
    CAST(pm.[SRPValue]
         / NULLIF(SUM(pm.[SRPValue]) OVER (PARTITION BY pm.[YearMonth]), 0)
         AS decimal(8,4))                                                 AS [ShareOfMonth],
    LAG(pm.[UnitsSold]) OVER (PARTITION BY pm.[ProductID]
                              ORDER BY pm.[YearMonth])                    AS [PrevMonthUnits]
FROM ProductMonth AS pm;
GO

/*==============================================================================
  vw_InventoryAging
  One row per device still in the channel. Dead stock is defined here, once:
  180 days or more without selling.
==============================================================================*/
CREATE OR ALTER VIEW [dbo].[vw_InventoryAging]
AS
SELECT
    i.[InventoryID],
    i.[SnapshotDate],
    i.[IMEI],
    i.[ProductID],
    p.[MarketName],
    p.[Series],
    p.[Category],
    p.[PriceTier],
    p.[LifecycleStage],
    i.[DealerID],
    dl.[DealerName],
    dl.[DealerType],
    dl.[SizeTier],
    i.[Region],
    i.[DistributorID],
    dist.[DistributorName],
    i.[ReceiveDate],
    i.[InventoryDurationDays],
    i.[StockStatus],
    i.[SRP],
    i.[DealerPrice],
    CASE WHEN i.[InventoryDurationDays] <  30 THEN '1. Under 30 days'
         WHEN i.[InventoryDurationDays] <  90 THEN '2. 30 to 90 days'
         WHEN i.[InventoryDurationDays] < 180 THEN '3. 90 to 180 days'
         WHEN i.[InventoryDurationDays] < 365 THEN '4. 180 to 365 days'
         ELSE                                      '5. Over 365 days'
    END AS [AgeBucket],
    CASE WHEN i.[InventoryDurationDays] >= 180 THEN 1 ELSE 0 END AS [IsDeadStock],
    CASE WHEN i.[InventoryDurationDays] >= 90 AND i.[InventoryDurationDays] < 180
         THEN 1 ELSE 0 END                                       AS [IsAtRisk]
FROM [dbo].[FactInventory] AS i
INNER JOIN [dbo].[DimProduct]     AS p    ON p.[ProductID]        = i.[ProductID]
INNER JOIN [dbo].[DimDealer]      AS dl   ON dl.[DealerID]        = i.[DealerID]
INNER JOIN [dbo].[DimDistributor] AS dist ON dist.[DistributorID] = i.[DistributorID];
GO

/*==============================================================================
  vw_ChannelCoverage
  The core question of the whole project: for each product, how many months of
  stock is sitting in the channel relative to how fast it actually sells?

  Sell-out rate uses the last 3 months only. A 12-month average would flatter
  end-of-life models, because it counts months when they were still selling.
==============================================================================*/
CREATE OR ALTER VIEW [dbo].[vw_ChannelCoverage]
AS
WITH RecentSellOut AS (
    SELECT
        [ProductID],
        SUM([Quantity]) / 3.0 AS [AvgMonthlyUnits]
    FROM [dbo].[vw_SellOutDetail]
    WHERE [YearMonth] >= 202607          -- last 3 months of the dataset
    GROUP BY [ProductID]
),
StockHeld AS (
    SELECT
        [ProductID],
        COUNT(*)                                          AS [UnitsInChannel],
        SUM([DealerPrice])                                AS [ChannelValue],
        SUM(CASE WHEN [IsDeadStock] = 1 THEN 1 ELSE 0 END) AS [DeadStockUnits],
        SUM(CASE WHEN [IsDeadStock] = 1 THEN [DealerPrice] ELSE 0 END) AS [DeadStockValue],
        AVG(CAST([InventoryDurationDays] AS decimal(10,2)))            AS [AvgAgeDays]
    FROM [dbo].[vw_InventoryAging]
    GROUP BY [ProductID]
)
SELECT
    p.[ProductID],
    p.[MarketName],
    p.[Series],
    p.[PriceTier],
    p.[LifecycleStage],
    ISNULL(s.[UnitsInChannel], 0)   AS [UnitsInChannel],
    ISNULL(s.[ChannelValue], 0)     AS [ChannelValue],
    ISNULL(s.[DeadStockUnits], 0)   AS [DeadStockUnits],
    ISNULL(s.[DeadStockValue], 0)   AS [DeadStockValue],
    s.[AvgAgeDays],
    ISNULL(r.[AvgMonthlyUnits], 0)  AS [AvgMonthlyUnits],
    CASE WHEN ISNULL(r.[AvgMonthlyUnits], 0) > 0
         THEN CAST(s.[UnitsInChannel] / r.[AvgMonthlyUnits] AS decimal(10,1))
    END AS [MonthsOfCover],
    CASE
        WHEN ISNULL(s.[UnitsInChannel], 0) = 0                  THEN 'No stock'
        WHEN ISNULL(r.[AvgMonthlyUnits], 0) = 0                 THEN 'Not selling'
        WHEN s.[UnitsInChannel] / r.[AvgMonthlyUnits] > 9       THEN 'Severely overstocked'
        WHEN s.[UnitsInChannel] / r.[AvgMonthlyUnits] > 6       THEN 'Overstocked'
        WHEN s.[UnitsInChannel] / r.[AvgMonthlyUnits] < 1.5     THEN 'Understocked'
        ELSE 'Healthy'
    END AS [CoverageStatus],
    CASE
        WHEN ISNULL(r.[AvgMonthlyUnits], 0) = 0
             AND ISNULL(s.[UnitsInChannel], 0) > 0              THEN 'Clear through promotion'
        WHEN ISNULL(r.[AvgMonthlyUnits], 0) > 0
             AND s.[UnitsInChannel] / r.[AvgMonthlyUnits] > 9   THEN 'Stop replenishment'
        WHEN ISNULL(r.[AvgMonthlyUnits], 0) > 0
             AND s.[UnitsInChannel] / r.[AvgMonthlyUnits] > 6   THEN 'Reduce replenishment'
        WHEN ISNULL(r.[AvgMonthlyUnits], 0) > 0
             AND s.[UnitsInChannel] / r.[AvgMonthlyUnits] < 1.5 THEN 'Increase allocation'
        ELSE 'Maintain'
    END AS [RecommendedAction]
FROM [dbo].[DimProduct] AS p
LEFT JOIN StockHeld     AS s ON s.[ProductID] = p.[ProductID]
LEFT JOIN RecentSellOut AS r ON r.[ProductID] = p.[ProductID];
GO

/*==============================================================================
  vw_DealerScorecard
  Which dealers move stock, and which sit on it.
==============================================================================*/
CREATE OR ALTER VIEW [dbo].[vw_DealerScorecard]
AS
WITH SellOut AS (
    SELECT
        [DealerID],
        SUM([Quantity])  AS [UnitsSoldYear],
        SUM([SRPValue])  AS [SellOutValueYear],
        SUM(CASE WHEN [YearMonth] >= 202607 THEN [Quantity] ELSE 0 END) / 3.0
                         AS [AvgMonthlyUnits]
    FROM [dbo].[vw_SellOutDetail]
    GROUP BY [DealerID]
),
Stock AS (
    SELECT
        [DealerID],
        COUNT(*)                                                       AS [UnitsInStock],
        SUM([DealerPrice])                                             AS [StockValue],
        SUM(CASE WHEN [IsDeadStock] = 1 THEN 1 ELSE 0 END)             AS [DeadStockUnits],
        SUM(CASE WHEN [IsDeadStock] = 1 THEN [DealerPrice] ELSE 0 END) AS [DeadStockValue],
        AVG(CAST([InventoryDurationDays] AS decimal(10,2)))            AS [AvgAgeDays]
    FROM [dbo].[vw_InventoryAging]
    GROUP BY [DealerID]
)
SELECT
    dl.[DealerID],
    dl.[DealerName],
    dl.[DealerType],
    dl.[DealerCategory],
    dl.[SizeTier],
    dl.[Region],
    dl.[City],
    dist.[DistributorName],
    ISNULL(so.[UnitsSoldYear], 0)    AS [UnitsSoldYear],
    ISNULL(so.[SellOutValueYear], 0) AS [SellOutValueYear],
    ISNULL(st.[UnitsInStock], 0)     AS [UnitsInStock],
    ISNULL(st.[StockValue], 0)       AS [StockValue],
    ISNULL(st.[DeadStockUnits], 0)   AS [DeadStockUnits],
    ISNULL(st.[DeadStockValue], 0)   AS [DeadStockValue],
    st.[AvgAgeDays],
    CAST(1.0 * ISNULL(st.[DeadStockUnits], 0)
         / NULLIF(st.[UnitsInStock], 0) AS decimal(8,4)) AS [DeadStockRate],
    CASE WHEN ISNULL(so.[AvgMonthlyUnits], 0) > 0
         THEN CAST(st.[UnitsInStock] / so.[AvgMonthlyUnits] AS decimal(10,1))
    END AS [MonthsOfCover]
FROM [dbo].[DimDealer]        AS dl
LEFT JOIN SellOut             AS so   ON so.[DealerID] = dl.[DealerID]
LEFT JOIN Stock               AS st   ON st.[DealerID] = dl.[DealerID]
INNER JOIN [dbo].[DimDistributor] AS dist ON dist.[DistributorID] = dl.[DistributorID];
GO

PRINT '05 complete - 6 reporting views created.';
GO
GO


/*########## SECTION 6 of 6 : 06_validation.sql ##########*/

USE [ChannelAnalytics];
GO

/*==============================================================================
  06_validation.sql
  Run after 05. Every check should say PASS.

  The point of this script is not that the scripts ran without an error — it is
  that the data they produced is actually correct. Those are different things.
==============================================================================*/


SET NOCOUNT ON;

DECLARE @Results TABLE (
    CheckNo   int,
    CheckName nvarchar(70),
    Result    nvarchar(6),
    Detail    nvarchar(200)
);

/*-- 1 --*/
INSERT INTO @Results
SELECT 1, 'Sell-out row count in expected range',
       CASE WHEN COUNT(*) BETWEEN 125000 AND 145000 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT(FORMAT(COUNT(*), 'N0'), ' rows (expected about 134,800)')
FROM [dbo].[FactSellOut];

/*-- 2 --*/
INSERT INTO @Results
SELECT 2, 'Twelve complete months of sell-out',
       CASE WHEN COUNT(DISTINCT [YearMonth]) = 12 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT(COUNT(DISTINCT [YearMonth]), ' months, ',
              MIN([SellOutDate]), ' to ', MAX([SellOutDate]))
FROM [dbo].[vw_SellOutDetail];

/*-- 3 -- no rows lost in the slot joins */
INSERT INTO @Results
SELECT 3, 'Every planned unit became a sell-out row',
       CASE WHEN p.Planned = f.Actual THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('planned ', FORMAT(p.Planned,'N0'), ', inserted ', FORMAT(f.Actual,'N0'),
              ' (a gap means some random draw matched no product or dealer slot)')
FROM (SELECT SUM([UnitsTarget]) AS Planned FROM [dbo].[StagingDailyPlan]) AS p
CROSS JOIN (SELECT COUNT(*) AS Actual FROM [dbo].[FactSellOut]) AS f;

/*-- 4 --*/
INSERT INTO @Results
SELECT 4, 'IMEIs are unique and never reused across tables',
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT(COUNT(*), ' IMEIs appear in both sell-out and inventory')
FROM [dbo].[FactSellOut] AS s
INNER JOIN [dbo].[FactInventory] AS i ON i.[IMEI] = s.[IMEI];

/*-- 5 --*/
INSERT INTO @Results
SELECT 5, 'No orphaned dimension keys',
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT(COUNT(*), ' orphan rows')
FROM [dbo].[FactSellOut] AS f
WHERE NOT EXISTS (SELECT 1 FROM [dbo].[DimProduct] p WHERE p.[ProductID] = f.[ProductID])
   OR NOT EXISTS (SELECT 1 FROM [dbo].[DimDealer]  d WHERE d.[DealerID]  = f.[DealerID])
   OR NOT EXISTS (SELECT 1 FROM [dbo].[DimDate]    t WHERE t.[DateKey]   = f.[DateKey]);

/*-- 6 -- the product mix should land on the slot shares in DimProduct */
INSERT INTO @Results
SELECT 6, 'Entry series is 64-69 percent of units',
       CASE WHEN [Share] BETWEEN 0.64 AND 0.69 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('ECHO series = ', FORMAT([Share], 'P1'), ' of units (slots say 66.5%)')
FROM (
    SELECT CAST(1.0 * SUM(CASE WHEN [Series] = 'ECHO' THEN 1 ELSE 0 END)
                / COUNT(*) AS decimal(6,4)) AS [Share]
    FROM [dbo].[vw_SellOutDetail]
) AS x;

/*-- 7 -- each product must reach many dealers, not a fixed handful.
          This is the check that would have caught the pseudo-random flaw
          where every SKU only ever shipped to 10 of the 150 dealers.        */
INSERT INTO @Results
SELECT 7, 'Products reach a wide spread of dealers',
       CASE WHEN MIN([Dealers]) >= 25 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('fewest dealers reached by any SKU = ', MIN([Dealers]), ' of 150')
FROM (
    SELECT [ProductID], COUNT(DISTINCT [DealerID]) AS [Dealers]
    FROM [dbo].[FactSellOut] GROUP BY [ProductID]
) AS x;

/*-- 8 --*/
INSERT INTO @Results
SELECT 8, 'November is the peak month',
       CASE WHEN (SELECT TOP 1 [YearMonth] FROM [dbo].[vw_MonthlySellOut]
                  ORDER BY [UnitsSold] DESC) = 202511 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('peak month = ', (SELECT TOP 1 [YearMonth] FROM [dbo].[vw_MonthlySellOut]
                                ORDER BY [UnitsSold] DESC));

/*-- 9 --*/
INSERT INTO @Results
SELECT 9, 'Inventory ageing matches the intended distribution',
       CASE WHEN ABS([UnderThirty] - 0.287) < 0.03 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT('under 30 days = ', FORMAT([UnderThirty], 'P1'), ' (target 28.7%)')
FROM (
    SELECT CAST(1.0 * SUM(CASE WHEN [InventoryDurationDays] < 30 THEN 1 ELSE 0 END)
                / COUNT(*) AS decimal(6,4)) AS [UnderThirty]
    FROM [dbo].[FactInventory]
) AS x;

/*-- 10 -- dead stock should sit in end-of-life models, not spread evenly */
INSERT INTO @Results
SELECT 10, 'Dead stock concentrates in end-of-life models',
       CASE WHEN [Share] > 0.55 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT(FORMAT([Share], 'P1'), ' of dead stock is end-of-life SKUs')
FROM (
    SELECT CAST(1.0 * SUM(CASE WHEN [LifecycleStage] = 'End-of-life' THEN 1 ELSE 0 END)
                / NULLIF(COUNT(*), 0) AS decimal(6,4)) AS [Share]
    FROM [dbo].[vw_InventoryAging] WHERE [IsDeadStock] = 1
) AS x;

/*-- 11 --*/
INSERT INTO @Results
SELECT 11, 'Receive date and ageing days agree',
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT(COUNT(*), ' rows where snapshot minus receive date <> duration')
FROM [dbo].[FactInventory]
WHERE DATEDIFF(DAY, [ReceiveDate], [SnapshotDate]) <> [InventoryDurationDays];

/*-- 12 --*/
INSERT INTO @Results
SELECT 12, 'Coverage view produces more than one status',
       CASE WHEN COUNT(DISTINCT [CoverageStatus]) >= 3 THEN 'PASS' ELSE 'FAIL' END,
       CONCAT(COUNT(DISTINCT [CoverageStatus]), ' distinct coverage statuses')
FROM [dbo].[vw_ChannelCoverage];

SELECT * FROM @Results ORDER BY [CheckNo];

/*==============================================================================
  Headline numbers
==============================================================================*/
PRINT '';
PRINT '--- Monthly sell-out ---';
SELECT [YearMonth], [UnitsSold], [SRPValue], [AvgSellingPrice],
       [ActiveDealers], [MoMGrowth]
FROM [dbo].[vw_MonthlySellOut] ORDER BY [YearMonth];

PRINT '--- Channel position ---';
SELECT
    (SELECT COUNT(*) FROM [dbo].[FactSellOut])                        AS [UnitsSoldYear],
    (SELECT SUM([SRPValue]) FROM [dbo].[FactSellOut])                 AS [SellOutValueSRP],
    (SELECT COUNT(*) FROM [dbo].[FactInventory])                      AS [UnitsInChannel],
    (SELECT SUM([DealerPrice]) FROM [dbo].[FactInventory])            AS [ChannelValueAtDealerPrice],
    CAST((SELECT COUNT(*) FROM [dbo].[FactInventory]) * 12.0
         / NULLIF((SELECT COUNT(*) FROM [dbo].[FactSellOut]), 0) AS decimal(6,1)) AS [MonthsOfCover];

PRINT '--- Inventory ageing ---';
SELECT
    [AgeBucket],
    COUNT(*)              AS [Units],
    SUM([DealerPrice])    AS [ValueAtDealerPrice],
    CAST(1.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS decimal(6,4)) AS [ShareOfUnits]
FROM [dbo].[vw_InventoryAging]
GROUP BY [AgeBucket] ORDER BY [AgeBucket];

PRINT '--- Products to stop replenishing ---';
SELECT [ProductID], [MarketName], [LifecycleStage], [UnitsInChannel],
       [AvgMonthlyUnits], [MonthsOfCover], [DeadStockUnits], [DeadStockValue],
       [CoverageStatus], [RecommendedAction]
FROM [dbo].[vw_ChannelCoverage]
WHERE [RecommendedAction] IN ('Stop replenishment','Clear through promotion','Reduce replenishment')
ORDER BY [DeadStockValue] DESC;

PRINT '--- Dealers holding the most dead stock ---';
SELECT TOP 15 [DealerName], [DealerType], [Region], [SizeTier],
       [UnitsSoldYear], [UnitsInStock], [DeadStockUnits], [DeadStockValue],
       [DeadStockRate], [MonthsOfCover]
FROM [dbo].[vw_DealerScorecard]
ORDER BY [DeadStockValue] DESC;
GO
GO
