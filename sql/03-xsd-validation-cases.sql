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

MAX_XML_BYTES = 1024 * 1024
MAX_XSD_BYTES = 256 * 1024
MAX_NESTING_DEPTH = 64
XSD_NAMESPACE = "http://www.w3.org/2001/XMLSchema"

def parser():
    return etree.XMLParser(
        resolve_entities=False,
        load_dtd=False,
        no_network=True,
        huge_tree=False,
    )

class DepthLimitExceeded(Exception):
    pass

class DoctypeRejected(Exception):
    pass

class PreflightTarget:
    def __init__(self, max_depth):
        self.max_depth = max_depth
        self.depth = 0

    def start(self, tag, attributes):
        self.depth += 1
        if self.depth > self.max_depth:
            raise DepthLimitExceeded()

    def end(self, tag):
        self.depth -= 1

    def data(self, data):
        pass

    def comment(self, text):
        pass

    def pi(self, target, data):
        pass

    def doctype(self, name, public_id, system_id):
        raise DoctypeRejected()

    def close(self):
        return None

def preflight(document_bytes):
    guarded_parser = etree.XMLParser(
        target=PreflightTarget(MAX_NESTING_DEPTH),
        resolve_entities=False,
        load_dtd=False,
        no_network=True,
        huge_tree=False,
    )
    etree.fromstring(document_bytes, guarded_parser)

try:
    xsd_bytes = xsd_text.encode("utf-8")
    if len(xsd_bytes) > MAX_XSD_BYTES:
        return json.dumps({"valid": False, "stage": "xsd_parse", "category": "xsd_too_large"})
    preflight(xsd_bytes)
    xsd_root = etree.fromstring(xsd_bytes, parser())
    external_schema_tags = {
        f"{{{XSD_NAMESPACE}}}include",
        f"{{{XSD_NAMESPACE}}}import",
        f"{{{XSD_NAMESPACE}}}redefine",
        f"{{{XSD_NAMESPACE}}}override",
    }
    if any(element.tag in external_schema_tags for element in xsd_root.iter()):
        return json.dumps({"valid": False, "stage": "xsd_parse", "category": "external_schema_reference_rejected"})
except etree.XMLSyntaxError as exc:
    return json.dumps({"valid": False, "stage": "xsd_parse", "category": "malformed_xsd", "detail": str(exc)})
except DepthLimitExceeded:
    return json.dumps({"valid": False, "stage": "xsd_parse", "category": "xsd_too_deep"})
except DoctypeRejected:
    return json.dumps({"valid": False, "stage": "xsd_parse", "category": "doctype_rejected"})

try:
    schema = etree.XMLSchema(xsd_root)
except etree.XMLSchemaParseError as exc:
    return json.dumps({"valid": False, "stage": "xsd_compile", "category": "invalid_xsd", "detail": str(exc)})

try:
    xml_bytes = xml_text.encode("utf-8")
    if len(xml_bytes) > MAX_XML_BYTES:
        return json.dumps({"valid": False, "stage": "xml_parse", "category": "xml_too_large"})
    preflight(xml_bytes)
    xml_root = etree.fromstring(xml_bytes, parser())
except etree.XMLSyntaxError as exc:
    return json.dumps({"valid": False, "stage": "xml_parse", "category": "malformed_xml", "detail": str(exc)})
except DepthLimitExceeded:
    return json.dumps({"valid": False, "stage": "xml_parse", "category": "xml_too_deep"})
except DoctypeRejected:
    return json.dumps({"valid": False, "stage": "xml_parse", "category": "doctype_rejected"})

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

-- Deliberately exercise a small, explicit policy for this lab helper:
-- 1 MiB XML, 256 KiB XSD, and at most 64 nested elements.
INSERT INTO xml_validation_cases
SELECT 'xml_too_large',
       '<employee><firstName>' || repeat('x', 1048576) || '</firstName><salary>1200.50</salary><hireDate>2024-01-31</hireDate></employee>',
       '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:element name="employee"><xs:complexType><xs:sequence><xs:element name="firstName" type="xs:string"/><xs:element name="salary" type="xs:decimal"/><xs:element name="hireDate" type="xs:date"/></xs:sequence></xs:complexType></xs:element></xs:schema>',
       false,
       'xml_too_large';

INSERT INTO xml_validation_cases
SELECT 'xsd_too_large',
       '<employee><firstName>Ada</firstName><salary>1200.50</salary><hireDate>2024-01-31</hireDate></employee>',
       '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:element name="employee" type="xs:string"/></xs:schema>' || repeat(' ', 262144),
       false,
       'xsd_too_large';

INSERT INTO xml_validation_cases
SELECT 'xml_too_deep',
       repeat('<level>', 65) || 'value' || repeat('</level>', 65),
       '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:element name="employee" type="xs:string"/></xs:schema>',
       false,
       'xml_too_deep';

INSERT INTO xml_validation_cases
SELECT 'xsd_too_deep',
       '<employee/>',
       '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:annotation>' || repeat('<xs:appinfo>', 63) || repeat('</xs:appinfo>', 63) || '</xs:annotation></xs:schema>',
       false,
       'xsd_too_deep';

INSERT INTO xml_validation_cases VALUES
('xsd_import_rejected',
 '<employee/>',
 '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:import namespace="urn:external" schemaLocation="https://127.0.0.1:9/external.xsd"/><xs:element name="employee" type="xs:string"/></xs:schema>',
 false, 'external_schema_reference_rejected'),
('xsd_include_rejected',
 '<employee/>',
 '<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"><xs:include schemaLocation="file:///etc/passwd"/><xs:element name="employee" type="xs:string"/></xs:schema>',
 false, 'external_schema_reference_rejected');

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
    actual_sqlstate text;
    actual_message text;
    expected_message text;
BEGIN
    FOR invalid_case IN
        SELECT * FROM xml_validation_cases WHERE expected_valid = false
    LOOP
        BEGIN
            PERFORM xml_research.persist_employee_xml(invalid_case.xml_text, invalid_case.xsd_text);
            RAISE EXCEPTION 'Case % unexpectedly persisted', invalid_case.case_id;
        EXCEPTION WHEN SQLSTATE '22023' THEN
            GET STACKED DIAGNOSTICS
                actual_sqlstate = RETURNED_SQLSTATE,
                actual_message = MESSAGE_TEXT;

            SELECT format('XML rejected during %s: %s', validation_stage, validation_category)
              INTO expected_message
              FROM xml_validation_results
             WHERE case_id = invalid_case.case_id;

            IF actual_sqlstate <> '22023' OR actual_message IS DISTINCT FROM expected_message THEN
                RAISE EXCEPTION 'Case % returned unexpected SQL error: [%] %',
                    invalid_case.case_id, actual_sqlstate, actual_message;
            END IF;
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

\echo 'Untrusted PL/Python privilege boundary'
DO $$
BEGIN
    IF (SELECT lanpltrusted FROM pg_language WHERE lanname = 'plpython3u') IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'Expected plpython3u to be marked as an untrusted language';
    END IF;
END
$$;

BEGIN;
CREATE ROLE xml_research_unprivileged NOLOGIN;
GRANT CREATE ON SCHEMA xml_research TO xml_research_unprivileged;
SET ROLE xml_research_unprivileged;
DO $$
BEGIN
    BEGIN
        EXECUTE 'CREATE FUNCTION xml_research.must_not_be_created() RETURNS integer LANGUAGE plpython3u AS $py$ return 1 $py$';
        RAISE EXCEPTION 'A non-superuser role unexpectedly created a plpython3u function';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'Non-superuser role was denied permission to create a plpython3u function';
    END;
END
$$;
RESET ROLE;
ROLLBACK;

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
