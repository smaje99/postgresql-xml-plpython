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
