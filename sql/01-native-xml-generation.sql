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

DO $$
DECLARE
    actual_document text;
    expected_document text;
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
END
$$;

SELECT 'generated XML matches expected fixture' AS assertion,
       XMLSERIALIZE(DOCUMENT generated.document AS text) = expected.document_text AS passed
  FROM generated_employee_xml AS generated
 CROSS JOIN expected_employee_xml AS expected;
