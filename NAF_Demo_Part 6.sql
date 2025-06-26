/*********************************************************************************************************
-- PART 6: Semantic Models
*********************************************************************************************************/

CREATE OR REPLACE STAGE semantic_files ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') DIRECTORY = ( ENABLE = true );

COPY FILES
INTO @semantic_files/
FROM @MY_CORTEX_AGENT_DB.PUBLIC.git_repo/branches/main/
FILES = ('semantic.yaml', 'semantic_search.yaml');

/*********************************************************************************************************
-- PART 7: Cortex Analyst and Cortex Search Integration
*********************************************************************************************************/

-- create a new search service
CREATE OR REPLACE CORTEX SEARCH SERVICE _ARTICLE_NAME_SEARCH
  ON ARTICLE_NAME
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 hour'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
AS (
    SELECT DISTINCT ARTICLE_NAME
    FROM DIM_ARTICLE
);