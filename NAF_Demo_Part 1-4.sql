
/*********************************************************************************************************
-- PART 0: Spining up a new Snowflake account and be the admin
*********************************************************************************************************/
https://signup.snowflake.com/

Choose the following options:

Enterprise (Most popular)
AWS Amazon Web Services 
US West (Oregon)

https://app.snowflake.com/cugjeuj/kjb24563/#/homepage
Username: JULIETTEHUYEN 
Dedicated Login URL: https://cugjeuj-kjb24563.snowflakecomputing.com 


Then log into your database

/*********************************************************************************************************
-- PART 1: Git Integration Demo
*********************************************************************************************************/


/***********************************************************************
-- Create a brand new database to host our NAF demo
***********************************************************************/

CREATE OR REPLACE DATABASE MY_CORTEX_AGENT_DB;


/***********************************************************************
-- Pull from GIT
***********************************************************************/

CREATE OR REPLACE API INTEGRATION git_api_integration
  API_PROVIDER = git_https_api
  API_ALLOWED_PREFIXES = ('https://github.com/Juliette-Huyen/')
  ENABLED = TRUE;

CREATE OR REPLACE GIT REPOSITORY git_repo
    api_integration = git_api_integration
    origin = 'https://github.com/Juliette-Huyen/NAF_Demo';

-- Make sure we get the latest files
ALTER GIT REPOSITORY git_repo FETCH;

-- Create an empty stage for docs
create or replace stage docs 
ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') DIRECTORY = ( ENABLE = true );

-- Copy the docs from folder to stage
COPY FILES
    INTO @docs/
    FROM @MY_CORTEX_AGENT_DB.PUBLIC.git_repo/branches/main/docs/;

ALTER STAGE docs REFRESH;

-- What s is in my stage table
LIST @MY_CORTEX_AGENT_DB.PUBLIC.docs

/*********************************************************************************************************
-- PART 2: Processing PDF
*********************************************************************************************************/

/***********************************************************************
-- Review Snowflake Concept: 
***********************************************************************/
/*
    Internal Stage
    External Stage
*/




/***********************************************************************
-- What s in the directory
***********************************************************************/

-- Preview documents
SELECT * FROM DIRECTORY('@DOCS');


/***********************************************************************
-- Read/process the PDF files using SNOWFLAKE.CORTEX.PARSE_DOCUMENT
-- Create a new table to store the result
***********************************************************************/

CREATE OR REPLACE TEMPORARY TABLE RAW_TEXT AS
SELECT 
    RELATIVE_PATH,
    TO_VARCHAR (
        SNOWFLAKE.CORTEX.PARSE_DOCUMENT (
            '@DOCS',
            RELATIVE_PATH,
            {'mode': 'LAYOUT'} ):content
        ) AS EXTRACTED_LAYOUT 
FROM 
    DIRECTORY('@DOCS')
WHERE
    RELATIVE_PATH LIKE '%.pdf';

/*
Juliette's Note: PARSE_DOCUMENT function with a smaller warehouse (no larger than MEDIUM) because larger warehouses do not increase performance. 
https://docs.snowflake.com/en/user-guide/snowflake-cortex/aisql
*/

/***********************************************************************
-- What s in the new table
***********************************************************************/

select * from RAW_TEXT limit 10;

/***********************************************************************
-- Create a new table to store the result of next step
-- breaking up the long text into chunks
***********************************************************************/

create or replace TABLE DOCS_CHUNKS_TABLE ( 
    RELATIVE_PATH VARCHAR(16777216), -- Relative path to the PDF file
    CHUNK VARCHAR(16777216), -- Piece of text
    CHUNK_INDEX INTEGER, -- Index for the text
    CATEGORY VARCHAR(16777216) -- Will hold the document category to enable filtering
);



INSERT INTO DOCS_CHUNKS_TABLE (relative_path, chunk, chunk_index)
    SELECT relative_path
    ,  c.value::TEXT as chunk
    , c.INDEX::INTEGER as chunk_index 
    FROM raw_text,
        LATERAL FLATTEN( input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER (
              EXTRACTED_LAYOUT,
              'markdown',
              1512,
              256,
              ['\n\n', '\n', ' ', '']
           )) c;

/***********************************************************************
-- Classify documents
***********************************************************************/


CREATE OR REPLACE TEMPORARY TABLE docs_categories AS 
    WITH unique_documents AS (
        SELECT DISTINCT relative_path, chunk
        FROM docs_chunks_table
        WHERE chunk_index = 0
    ),

    docs_category_cte AS (
        SELECT
        relative_path
        , TRIM(snowflake.cortex.CLASSIFY_TEXT (
            'Title:' || relative_path || 'Content:' || chunk, ['Bike', 'Snow']
            )['label'], '"') AS category
    FROM unique_documents
    )

    SELECT *
    FROM docs_category_cte;


/***********************************************************************
-- What s in the new table
***********************************************************************/

SELECT * FROM DOCS_CHUNKS_TABLE limit 10;

UPDATE docs_chunks_table 
SET category = docs_categories.category
FROM docs_categories
WHERE docs_chunks_table.relative_path = docs_categories.relative_path;

SELECT * FROM DOCS_CHUNKS_TABLE limit 10;


/*
Note on Snowflake UPDATE syntax

In SQL Server, or other databases

UPDATE docs_chunks_table 
SET category = docs_categories.category
FROM docs_chunks_table
INNER JOIN docs_categories 
ON docs_chunks_table.relative_path = docs_categories.relative_path;

What's about LEFT JOJN on UPDATE in Snowflake
*/

/*********************************************************************************************************
-- PART 3: Processing Images
*********************************************************************************************************/


/***********************************************************************
-- Reuse the Chunk table from previous steps
-- Again - breaking up the long text into chunks
***********************************************************************/

INSERT INTO DOCS_CHUNKS_TABLE (relative_path, chunk, chunk_index, category)
    SELECT RELATIVE_PATH
    , CONCAT('This is a picture describing the bike: '|| RELATIVE_PATH || ' - ' ||
        'THIS IS THE DESCRIPTION: ' ||
        SNOWFLAKE.CORTEX.COMPLETE('claude-3-5-sonnet',
            'DESCRIBE THIS IMAGE: ',
            TO_FILE('@DOCS', RELATIVE_PATH)
        )
    ) AS chunk
    , 0 AS chunk_index
    , SNOWFLAKE.CORTEX.COMPLETE('claude-3-5-sonnet'
        , 'Classify this image, respond only with Bike or Snow: '
        , TO_FILE('@DOCS', RELATIVE_PATH)) AS category
FROM 
    DIRECTORY('@DOCS')
WHERE
    RELATIVE_PATH LIKE '%.jpeg';


/*
What are other options:
claude-3-5-sonnet


*/


/***********************************************************************
-- Whats in the new table
***********************************************************************/

SELECT * FROM DOCS_CHUNKS_TABLE
WHERE RELATIVE_PATH LIKE '%.jpeg';


/*********************************************************************************************************
-- PART 4: Cortex Search

Cortex Search tool will be used to retrieve context from unstructured data. 
Once we have processed all the content from PDFs and images into the DOCS_CHUNK_TABLE, we just need to enable the service in that table. 
This will automatically create the embeddings, indexing, etc. 
*********************************************************************************************************/


SHOW WAREHOUSES;


-- Because this can be resource intensive, we may need a dedicated warehouse for this service
CREATE WAREHOUSE IF NOT EXISTS DEDICATE_WH
WAREHOUSE_SIZE = 'XSMALL';


CREATE OR REPLACE CORTEX SEARCH SERVICE DOCUMENTATION_TOOL
ON chunk
ATTRIBUTES relative_path, category
warehouse = COMPUTE_WH  -- or this a dedicated warehouse
TARGET_LAG = '1 hour'
EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
AS (
    SELECT chunk
    , chunk_index
    , relative_path
    , category
    from docs_chunks_table
);


