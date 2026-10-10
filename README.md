# PostgreSQL XML and PL/Python lab

Reproducible, database-side examples for the two-part article series on XML in PostgreSQL. The experiments use PostgreSQL 18.6, native SQL/XML, and `plpython3u` with lxml. PostgreSQL 19 is tracked separately in the editorial research; this repository does not claim tested PostgreSQL 19 behavior.

The sample data is synthetic. The scripts compare PostgreSQL's well-formedness checks and SQL/XML projection with XSD validation inside the database. The lxml function is an experimental lab helper, not a production-ready validation API. Application-side validation is discussed in the retrospective article but is not part of this runnable comparison.

## Requirements

- Docker Engine with the Docker Compose plugin.
- A local password used only for this disposable container.
- A free local TCP port (the default is `55433`).

The container exposes PostgreSQL only on `127.0.0.1`. `plpython3u` is an untrusted procedural language, so use this project only in the isolated local container. Do not connect it to production data or reuse a production password.

## Run the examples

```sh
cp .env.example .env
```

Generate a local password with Python's standard `secrets` library:

```sh
python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
```

Put the generated value in `.env` as `POSTGRES_PASSWORD`. Then start PostgreSQL:

```sh
docker compose up --build -d
docker compose ps
```

Run the runtime probe, relational-to-XML generation case, native SQL/XML and namespace checks, and XSD validation/persistence matrix:

```sh
docker compose run --rm --no-deps postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /workspace/sql/00-runtime-smoke.sql'
docker compose run --rm --no-deps postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /workspace/sql/01-native-xml-generation.sql'
docker compose run --rm --no-deps postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /workspace/sql/02-native-sql-xml.sql'
docker compose run --rm --no-deps postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /workspace/sql/03-xsd-validation-cases.sql'
```

The generation script uses separate CSV inputs and an expected XML document. It verifies that `XMLELEMENT`, `XMLATTRIBUTES`, `XMLFOREST`, and ordered `XMLAGG` produce the expected document, including escaped text, omitted null fields, and multiple history elements in order.

The native SQL/XML script checks a default-namespace document both without a namespace mapping (zero rows) and with an explicit alias in `XMLNAMESPACES` (typed values extracted).

The validation/persistence script:

- compares PostgreSQL's XML well-formedness check with lxml XSD validation;
- exercises 11 valid and invalid XML/XSD cases;
- persists two valid documents by projecting them with `XMLTABLE`;
- verifies that malformed and XSD-invalid documents are rejected without inserting rows;
- keeps validation inputs and expected outcomes in `fixtures/xsd-validation-insertion/`.

Expected results: the generated XML matches `fixtures/xml-generation/expected-employees.xml`; namespace assertions pass; every validation case reports `matches_expected = t`; valid documents persist and invalid documents are rejected.

Stop the database when finished:

```sh
docker compose stop
```

The volume remains so a later `docker compose start` can resume the container. To remove the container, network, and experimental database volume:

```sh
docker compose down --volumes
```

## Tested environment

The recorded run used the official `postgres:18.6-bookworm` image, PostgreSQL `18.6-1.pgdg12+2`, Python 3.11.2, lxml 4.9.2.0, and libxml2 2.9.14. The image tag is pinned to the PostgreSQL 18.6 Bookworm build used for the article experiments; OS package repositories can change, so check the runtime probe after rebuilding.

## Scope and interpretation

PostgreSQL native XML support checks well-formedness and provides SQL/XML and XPath operations; it does not validate arbitrary documents against XSD. In these experiments, lxml runs inside PostgreSQL through `plpython3u` to validate the supplied schema before `XMLTABLE` extracts typed values for insertion.

The helper disables entity resolution, DTD loading, network access, and huge-tree mode, and rejects documents with DTD declarations. The cases exercise these settings but do not constitute a complete parser security review. Schema imports/includes, size and depth limits, privilege boundaries, production error handling, and performance are outside the current test coverage.

## License and attribution

This example project is licensed under GNU GPL version 3 only (`GPL-3.0-only`); see [LICENSE](LICENSE). It includes a disclaimer of warranty and copyleft terms: when you convey a covered modified version, GPLv3 requires preserving the license and providing the corresponding source as its terms specify. The original university lab files are intentionally not copied here; their source and GPLv3 notice remain in the research workspace.
