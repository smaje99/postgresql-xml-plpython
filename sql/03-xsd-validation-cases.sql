\set ON_ERROR_STOP on

\echo 'Database-side XML well-formedness and XSD validation cases'

CREATE EXTENSION IF NOT EXISTS plpython3u;
CREATE SCHEMA IF NOT EXISTS xml_research;

CREATE OR REPLACE FUNCTION xml_research.validate_xml_xsd_case(
    xml_text text,
    xsd_text text
)
RETURNS jsonb
LANGUAGE plpython3u
AS $$
import json
from lxml import etree

def parser():
    return etree.XMLParser(
        resolve_entities=False,
        load_dtd=False,
        no_network=True,
        huge_tree=False,
    )

try:
    xsd_root = etree.fromstring(xsd_text.encode("utf-8"), parser())
    if xsd_root.getroottree().docinfo.doctype:
        return json.dumps({"valid": False, "stage": "xsd_parse", "category": "doctype_rejected"})
    schema = etree.XMLSchema(xsd_root)
except etree.XMLSyntaxError as exc:
    return json.dumps({"valid": False, "stage": "xsd_parse", "category": "malformed_xsd", "detail": str(exc)})
except etree.XMLSchemaParseError as exc:
    return json.dumps({"valid": False, "stage": "xsd_compile", "category": "invalid_xsd", "detail": str(exc)})

try:
    xml_root = etree.fromstring(xml_text.encode("utf-8"), parser())
    if xml_root.getroottree().docinfo.doctype:
        return json.dumps({"valid": False, "stage": "xml_parse", "category": "doctype_rejected"})
except etree.XMLSyntaxError as exc:
    return json.dumps({"valid": False, "stage": "xml_parse", "category": "malformed_xml", "detail": str(exc)})

if schema.validate(xml_root):
    return json.dumps({"valid": True, "stage": "xsd_validation", "category": "valid"})

last_error = schema.error_log.last_error
return json.dumps({
    "valid": False,
    "stage": "xsd_validation",
    "category": "xsd_invalid",
    "detail": str(last_error) if last_error is not None else "XSD validation failed",
})
$$;

CREATE TEMP TABLE xml_validation_cases (
    case_id text PRIMARY KEY,
    xml_text text NOT NULL,
    xsd_text text NOT NULL,
    expected_valid boolean NOT NULL,
    expected_category text NOT NULL
);

\ir ../fixtures/xsd-validation-insertion/validation-cases.sql

CREATE TEMP TABLE xml_validation_results AS
SELECT c.case_id,
       xml_is_well_formed_document(c.xml_text) AS postgres_well_formed,
       (v.result->>'valid')::boolean AS xsd_valid,
       v.result->>'stage' AS validation_stage,
       v.result->>'category' AS validation_category,
       c.expected_valid,
       c.expected_category
  FROM xml_validation_cases AS c
 CROSS JOIN LATERAL (
       SELECT xml_research.validate_xml_xsd_case(c.xml_text, c.xsd_text) AS result
  ) AS v;

SELECT
    case_id,
    postgres_well_formed,
    xsd_valid,
    validation_stage,
    validation_category,
    xsd_valid = expected_valid AND validation_category = expected_category AS matches_expected
FROM xml_validation_results
ORDER BY case_id;

DO $$
DECLARE
    failed_cases text;
BEGIN
    SELECT string_agg(case_id, ', ' ORDER BY case_id)
      INTO failed_cases
      FROM xml_validation_results
     WHERE xsd_valid IS DISTINCT FROM expected_valid
        OR validation_category IS DISTINCT FROM expected_category;

    IF failed_cases IS NOT NULL THEN
        RAISE EXCEPTION 'Unexpected XML validation result(s): %', failed_cases;
    END IF;
END
$$;

\echo 'End-to-end database persistence and rejection assertions'
CREATE TEMP TABLE persisted_employees (
    first_name text NOT NULL,
    salary numeric NOT NULL,
    hire_date date NOT NULL,
    nickname text
);

CREATE OR REPLACE FUNCTION xml_research.persist_employee_xml(
    xml_text text,
    xsd_text text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    validation_result jsonb;
BEGIN
    validation_result := xml_research.validate_xml_xsd_case(xml_text, xsd_text);

    IF COALESCE((validation_result->>'valid')::boolean, false) IS NOT TRUE THEN
        RAISE EXCEPTION USING
            ERRCODE = '22023',
            MESSAGE = format(
                'XML rejected during %s: %s',
                validation_result->>'stage',
                validation_result->>'category'
            ),
            DETAIL = COALESCE(validation_result->>'detail', 'No parser detail was returned');
    END IF;

    INSERT INTO pg_temp.persisted_employees (first_name, salary, hire_date, nickname)
    SELECT first_name, salary, hire_date, nickname
      FROM XMLTABLE(
          '/employee'
          PASSING XMLPARSE(DOCUMENT xml_text)
          COLUMNS first_name text PATH 'firstName',
                  salary numeric PATH 'salary',
                  hire_date date PATH 'hireDate',
                  nickname text PATH 'nickname'
      ) AS employee;
END
$$;

SELECT xml_research.persist_employee_xml(xml_text, xsd_text)
  FROM xml_validation_cases
 WHERE case_id = 'valid';
SELECT xml_research.persist_employee_xml(xml_text, xsd_text)
  FROM xml_validation_cases
 WHERE case_id = 'valid_optional_element_present';

DO $$
DECLARE
    invalid_case record;
    persisted_count integer;
BEGIN
    FOR invalid_case IN
        SELECT * FROM xml_validation_cases WHERE expected_valid = false
    LOOP
        BEGIN
            PERFORM xml_research.persist_employee_xml(invalid_case.xml_text, invalid_case.xsd_text);
            RAISE EXCEPTION 'Case % unexpectedly persisted', invalid_case.case_id;
        EXCEPTION WHEN SQLSTATE '22023' THEN
            NULL;
        END;
    END LOOP;

    SELECT count(*) INTO persisted_count FROM persisted_employees;
    IF persisted_count <> 2 THEN
        RAISE EXCEPTION 'Expected exactly two valid documents persisted, got %', persisted_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM persisted_employees
         WHERE first_name = 'Ada'
           AND salary = 1200.50
           AND hire_date = DATE '2024-01-31'
           AND nickname IS NULL
    ) THEN
        RAISE EXCEPTION 'Valid XML fields were not extracted and persisted as expected';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM persisted_employees
         WHERE first_name = 'Ada'
           AND salary = 1200.50
           AND hire_date = DATE '2024-01-31'
           AND nickname = 'Countess'
    ) THEN
        RAISE EXCEPTION 'Optional XML field was not extracted and persisted';
    END IF;
END
$$;

\echo 'Native XMLTABLE projection with an explicitly mapped namespace'
SELECT *
FROM XMLTABLE(
    XMLNAMESPACES('urn:employee' AS e),
    '/e:employee'
    PASSING XMLPARSE(DOCUMENT '<e:employee xmlns:e="urn:employee"><e:firstName>Ada</e:firstName><e:salary>1200.50</e:salary></e:employee>')
    COLUMNS first_name text PATH 'e:firstName',
            salary numeric PATH 'e:salary'
) AS employee;

DROP FUNCTION xml_research.validate_xml_xsd_case(text, text);
DROP FUNCTION xml_research.persist_employee_xml(text, text);
DROP SCHEMA xml_research;
