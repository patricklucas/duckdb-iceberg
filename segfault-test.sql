CREATE VIEW index AS
  SELECT * FROM iceberg_scan('data/persistent/segfault_issue');

CREATE OR REPLACE VIEW root_clordids AS
  WITH RECURSIVE root_ClOrdIDs(ClOrdID, root_ClOrdID) AS (
    SELECT DISTINCT ClOrdID, ClOrdID AS root_ClOrdID
    FROM index AS messages
    WHERE origClOrdID IS NULL

    UNION ALL

    SELECT messages.ClOrdID, root_ClOrdIDs.root_ClOrdID
    FROM (SELECT DISTINCT ClOrdID, OrigClOrdID FROM index) AS messages
    INNER JOIN root_ClOrdIDs ON messages.origClOrdID = root_ClOrdIDs.ClOrdID
  )
  SELECT * FROM root_ClOrdIDs;
