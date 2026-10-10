\set ON_ERROR_STOP on

\echo 'Historical HR XML output against the original employee_schema.xml'

CREATE EXTENSION IF NOT EXISTS plpython3u;

CREATE TEMP TABLE historical_employees (
    employee_id integer PRIMARY KEY,
    first_name text NOT NULL,
    last_name text NOT NULL,
    email text NOT NULL
);

CREATE TEMP TABLE historical_job_history (
    employee_id integer NOT NULL,
    start_date timestamp NOT NULL,
    end_date timestamp NOT NULL,
    job_id text NOT NULL,
    department_id integer NOT NULL
);

CREATE TEMP TABLE historical_jobs (
    job_id text PRIMARY KEY,
    job_title text NOT NULL
);

CREATE TEMP TABLE historical_departments (
    department_id integer PRIMARY KEY,
    department_name text NOT NULL
);

\copy historical_employees (employee_id, first_name, last_name, email) FROM '/workspace/fixtures/historical-output/employees.csv' WITH (FORMAT csv, HEADER true)
\copy historical_job_history (employee_id, start_date, end_date, job_id, department_id) FROM '/workspace/fixtures/historical-output/job-history.csv' WITH (FORMAT csv, HEADER true)

INSERT INTO historical_jobs (job_id, job_title) VALUES
    ('DEV', 'Software Developer'),
    ('DBA', 'Database Administrator');

INSERT INTO historical_departments (department_id, department_name) VALUES
    (10, 'Engineering'),
    (20, 'Data Platform');

CREATE TEMP TABLE historical_employee_schema (
    line_number integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schema_line text NOT NULL
);
\copy historical_employee_schema (schema_line) FROM '/workspace/fixtures/historical-output/employee_schema.xml'

CREATE TEMP TABLE historical_output_cases (
    employee_id integer PRIMARY KEY,
    case_name text NOT NULL,
    expected_history_count integer NOT NULL,
    expected_xml_history_elements integer NOT NULL,
    expected_schema_valid boolean NOT NULL
);

INSERT INTO historical_output_cases VALUES
    (9001, 'zero_history', 0, 1, false),
    (9002, 'one_history', 1, 1, true),
    (9003, 'multiple_history', 2, 2, false);

CREATE TEMP TABLE historical_generated_xml AS
SELECT employee.employee_id,
       XMLELEMENT(
           NAME "employee",
           XMLATTRIBUTES(employee.employee_id AS "id"),
           XMLFOREST(
               employee.employee_id AS "employeeId",
               employee.first_name AS "firstName",
               employee.last_name AS "lastName",
               employee.email AS "email",
               XMLAGG(
                   XMLELEMENT(
                       NAME "jobHistory",
                       XMLFOREST(
                           history.start_date AS "startDate",
                           history.end_date AS "endDate",
                           job.job_title AS "jobTitle",
                           department.department_name AS "departmentName"
                       )
                   )
               ) AS "jobHistories"
           )
       ) AS document
  FROM historical_employees AS employee
  LEFT JOIN historical_job_history AS history
    ON history.employee_id = employee.employee_id
  LEFT JOIN historical_jobs AS job
    ON job.job_id = history.job_id
  LEFT JOIN historical_departments AS department
    ON department.department_id = history.department_id
 GROUP BY employee.employee_id,
          employee.first_name,
          employee.last_name,
          employee.email;

CREATE FUNCTION pg_temp.validate_historical_employee_xml(xml_text text, xsd_text text)
RETURNS TABLE(is_valid boolean, validation_error text)
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

if xml_schema.validate(document):
    return [(True, None)]

last_error = xml_schema.error_log.last_error
error_message = None if last_error is None else last_error.message
return [(False, error_message)]
$$;

CREATE TEMP TABLE historical_validation_results AS
WITH source_schema AS (
    SELECT string_agg(schema_line, E'\n' ORDER BY line_number) AS schema_text
      FROM historical_employee_schema
)
SELECT test_case.case_name,
       test_case.employee_id,
       test_case.expected_history_count,
       test_case.expected_xml_history_elements,
       test_case.expected_schema_valid,
       history_counts.payload_history_count AS actual_history_count,
       history_counts.xml_history_element_count AS actual_xml_history_elements,
       validation.is_valid AS actual_schema_valid,
       validation.validation_error
  FROM historical_output_cases AS test_case
  JOIN historical_generated_xml AS generated USING (employee_id)
 CROSS JOIN source_schema
 CROSS JOIN LATERAL pg_temp.validate_historical_employee_xml(
     XMLSERIALIZE(DOCUMENT generated.document AS text), source_schema.schema_text
 ) AS validation
  LEFT JOIN LATERAL (
      SELECT count(*)::integer AS xml_history_element_count,
             count(history_node.job_title)::integer AS payload_history_count
        FROM XMLTABLE(
            '/employee/jobHistories/jobHistory'
            PASSING generated.document
            COLUMNS job_title text PATH 'jobTitle'
        ) AS history_node
  ) AS history_counts ON true
 GROUP BY test_case.case_name,
          test_case.employee_id,
          test_case.expected_history_count,
          test_case.expected_xml_history_elements,
          test_case.expected_schema_valid,
          history_counts.payload_history_count,
          history_counts.xml_history_element_count,
          validation.is_valid,
          validation.validation_error;

SELECT case_name,
       expected_history_count,
       actual_history_count,
       expected_xml_history_elements,
       actual_xml_history_elements,
       expected_schema_valid,
       actual_schema_valid,
       validation_error,
       expected_history_count = actual_history_count
       AND expected_xml_history_elements = actual_xml_history_elements
       AND expected_schema_valid = actual_schema_valid AS matches_expected
  FROM historical_validation_results
 ORDER BY employee_id;

DO $$
DECLARE
    mismatches text;
BEGIN
    SELECT string_agg(case_name, ', ' ORDER BY employee_id)
      INTO mismatches
      FROM historical_validation_results
     WHERE expected_history_count <> actual_history_count
        OR expected_xml_history_elements <> actual_xml_history_elements
        OR expected_schema_valid IS DISTINCT FROM actual_schema_valid;

    IF mismatches IS NOT NULL THEN
        RAISE EXCEPTION 'Historical XML/XSD expectations did not match: %', mismatches;
    END IF;
END
$$;
