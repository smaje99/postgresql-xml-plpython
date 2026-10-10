\set ON_ERROR_STOP on

\echo 'XMLPARSE, XMLSERIALIZE, document predicate'
SELECT XMLSERIALIZE(
    DOCUMENT XMLPARSE(DOCUMENT '<root><item>42</item></root>') AS text
) AS serialized_document;
SELECT XMLPARSE(DOCUMENT '<root/>') IS DOCUMENT AS is_document;

\echo 'XPath and namespace mapping'
SELECT xpath(
    '/r:item/text()',
    XMLPARSE(DOCUMENT '<r:item xmlns:r="urn:example">ok</r:item>'),
    ARRAY[ARRAY['r', 'urn:example']]
) AS xpath_value;
SELECT xpath_exists(
    '/r:item[text()="ok"]',
    XMLPARSE(DOCUMENT '<r:item xmlns:r="urn:example">ok</r:item>'),
    ARRAY[ARRAY['r', 'urn:example']]
) AS xpath_found;

\echo 'XMLEXISTS and XMLTABLE projection'
SELECT XMLEXISTS(
    '/root/item[text()="42"]'
    PASSING BY VALUE XMLPARSE(DOCUMENT '<root><item>42</item></root>')
) AS xml_exists;
SELECT *
FROM XMLTABLE(
    '/root/item'
    PASSING XMLPARSE(DOCUMENT '<root><item>42</item></root>')
    COLUMNS item_value integer PATH 'text()'
) AS items;

\echo 'XMLTABLE with a document default namespace'
WITH source(document) AS (
    VALUES (
        XMLPARSE(DOCUMENT
            '<employee xmlns="urn:employee"><firstName>Ada</firstName><salary>1200.50</salary></employee>'
        )
    )
)
SELECT count(*) AS rows_without_namespace_mapping
  FROM source,
       XMLTABLE(
           '/employee'
           PASSING source.document
           COLUMNS first_name text PATH 'firstName'
       ) AS employee;

WITH source(document) AS (
    VALUES (
        XMLPARSE(DOCUMENT
            '<employee xmlns="urn:employee"><firstName>Ada</firstName><salary>1200.50</salary></employee>'
        )
    )
)
SELECT employee.first_name, employee.salary
  FROM source,
       XMLTABLE(
           XMLNAMESPACES('urn:employee' AS e),
           '/e:employee'
           PASSING source.document
           COLUMNS first_name text PATH 'e:firstName',
                   salary numeric PATH 'e:salary'
       ) AS employee;

DO $$
DECLARE
    unmapped_count integer;
    mapped_name text;
BEGIN
    SELECT count(*)
      INTO unmapped_count
      FROM XMLTABLE(
          '/employee'
          PASSING XMLPARSE(DOCUMENT
              '<employee xmlns="urn:employee"><firstName>Ada</firstName></employee>'
          )
          COLUMNS first_name text PATH 'firstName'
      ) AS employee;

    IF unmapped_count <> 0 THEN
        RAISE EXCEPTION 'An unqualified XMLTABLE path unexpectedly matched a default-namespace document';
    END IF;

    SELECT employee.first_name
      INTO mapped_name
      FROM XMLTABLE(
          XMLNAMESPACES('urn:employee' AS e),
          '/e:employee'
          PASSING XMLPARSE(DOCUMENT
              '<employee xmlns="urn:employee"><firstName>Ada</firstName></employee>'
          )
          COLUMNS first_name text PATH 'e:firstName'
      ) AS employee;

    IF mapped_name IS DISTINCT FROM 'Ada' THEN
        RAISE EXCEPTION 'XMLTABLE namespace alias mapped unexpected value: %', mapped_name;
    END IF;
END
$$;
