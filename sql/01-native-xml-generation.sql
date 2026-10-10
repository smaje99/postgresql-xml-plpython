\set ON_ERROR_STOP on

\echo 'Relational rows to XML with XMLELEMENT, XMLATTRIBUTES, XMLFOREST, and XMLAGG'

CREATE TEMP TABLE generation_employees (
    employee_id integer PRIMARY KEY,
    first_name text NOT NULL,
    department text
);

CREATE TEMP TABLE generation_job_history (
    employee_id integer NOT NULL,
    start_date date NOT NULL,
    title text NOT NULL
);

\copy generation_employees (employee_id, first_name, department) FROM '/workspace/fixtures/xml-generation/employees.csv' WITH (FORMAT csv, HEADER true, NULL '')
\copy generation_job_history (employee_id, start_date, title) FROM '/workspace/fixtures/xml-generation/job-history.csv' WITH (FORMAT csv, HEADER true)

CREATE TEMP TABLE expected_employee_xml (document_text text NOT NULL);
-- Keep this fixture on one line so psql \copy imports it as one exact-comparison value.
\copy expected_employee_xml (document_text) FROM '/workspace/fixtures/xml-generation/expected-employees.xml'

CREATE TEMP TABLE employee_output_xsd (
    line_number integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schema_line text NOT NULL
);
\copy employee_output_xsd (schema_line) FROM '/workspace/fixtures/xml-generation/employees-output.xsd'

CREATE TEMP TABLE generated_employee_xml AS
SELECT XMLELEMENT(
           NAME employees,
           XMLAGG(
               XMLELEMENT(
                   NAME employee,
                   XMLATTRIBUTES(employee.employee_id AS id),
                   XMLFOREST(
                       employee.first_name AS "firstName",
                       employee.department
                   ),
                   history.history_xml
               ) ORDER BY employee.employee_id
           )
       ) AS document
  FROM generation_employees AS employee
  LEFT JOIN LATERAL (
      SELECT XMLAGG(
                 XMLELEMENT(
                     NAME "jobHistory",
                     XMLATTRIBUTES(job.start_date AS "startDate"),
                     XMLFOREST(job.title)
                 ) ORDER BY job.start_date
             ) AS history_xml
        FROM generation_job_history AS job
       WHERE job.employee_id = employee.employee_id
  ) AS history ON true;

SELECT XMLSERIALIZE(DOCUMENT document AS text) AS generated_document
  FROM generated_employee_xml;

CREATE FUNCTION pg_temp.validate_generated_employee_xml(xml_text text, xsd_text text)
RETURNS boolean
LANGUAGE plpython3u
AS $$
from lxml import etree

parser = etree.XMLParser(
    resolve_entities=False,
    load_dtd=False,
    no_network=True,
    huge_tree=False,
)
xsd_root = etree.fromstring(xsd_text.encode("utf-8"), parser=parser)
xml_schema = etree.XMLSchema(xsd_root)
document = etree.fromstring(xml_text.encode("utf-8"), parser=parser)
return xml_schema.validate(document)
$$;

DO $$
DECLARE
    actual_document text;
    expected_document text;
    output_schema text;
    employee_count integer;
    invalid_cardinality text;
BEGIN
    SELECT XMLSERIALIZE(DOCUMENT document AS text)
      INTO actual_document
      FROM generated_employee_xml;

    SELECT document_text
      INTO expected_document
      FROM expected_employee_xml;

    IF actual_document IS DISTINCT FROM expected_document THEN
        RAISE EXCEPTION 'Generated XML differs from the expected fixture'
            USING DETAIL = format(E'actual:   %s\nexpected: %s', actual_document, expected_document);
    END IF;

    IF xml_is_well_formed_document(actual_document) IS NOT TRUE THEN
        RAISE EXCEPTION 'Generated XML is not a well-formed XML document';
    END IF;

    SELECT string_agg(schema_line, E'\n' ORDER BY line_number)
      INTO output_schema
      FROM employee_output_xsd;

    IF pg_temp.validate_generated_employee_xml(actual_document, output_schema) IS NOT TRUE THEN
        RAISE EXCEPTION 'Generated XML does not satisfy the example output XSD';
    END IF;

    SELECT count(*)
      INTO employee_count
      FROM generated_employee_xml AS generated,
           XMLTABLE(
               '/employees/employee'
               PASSING generated.document
               COLUMNS employee_id integer PATH '@id'
           ) AS employees;

    IF employee_count <> 3 THEN
        RAISE EXCEPTION 'Expected three employee elements, found %', employee_count;
    END IF;

    IF xpath_exists('/employees/employee[@id="1002"]/department',
                    (SELECT document FROM generated_employee_xml)) THEN
        RAISE EXCEPTION 'A null department should be omitted from the generated XML';
    END IF;

    WITH actual_history_counts AS (
        SELECT employee.employee_id,
               count(history.start_date)::integer AS history_count
          FROM generated_employee_xml AS generated,
               XMLTABLE(
                   '/employees/employee'
                   PASSING generated.document
                   COLUMNS employee_id integer PATH '@id',
                           employee_xml xml PATH '.'
               ) AS employee
          LEFT JOIN LATERAL XMLTABLE(
              '/employee/jobHistory'
              PASSING employee.employee_xml
              COLUMNS start_date date PATH '@startDate'
          ) AS history ON true
         GROUP BY employee.employee_id
    ), expected_history_counts(employee_id, history_count) AS (
        VALUES (1001, 2), (1002, 0), (1003, 1)
    )
    SELECT string_agg(
               format('employee %s: expected %s history rows, found %s',
                      expected.employee_id,
                      expected.history_count,
                      coalesce(actual.history_count, -1)),
               '; ' ORDER BY expected.employee_id
           )
      INTO invalid_cardinality
      FROM expected_history_counts AS expected
      LEFT JOIN actual_history_counts AS actual USING (employee_id)
     WHERE actual.history_count IS DISTINCT FROM expected.history_count;

    IF invalid_cardinality IS NOT NULL THEN
        RAISE EXCEPTION 'Unexpected generated history cardinality: %', invalid_cardinality;
    END IF;
END
$$;

SELECT 'generated XML matches expected fixture and output XSD' AS assertion,
       XMLSERIALIZE(DOCUMENT generated.document AS text) = expected.document_text
       AND pg_temp.validate_generated_employee_xml(
           XMLSERIALIZE(DOCUMENT generated.document AS text), schema.schema_text
       ) AS passed
  FROM generated_employee_xml AS generated
 CROSS JOIN expected_employee_xml AS expected
 CROSS JOIN (
     SELECT string_agg(schema_line, E'\n' ORDER BY line_number) AS schema_text
       FROM employee_output_xsd
 ) AS schema;
