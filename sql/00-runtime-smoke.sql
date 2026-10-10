\echo 'PostgreSQL server and native XML smoke checks'
SELECT version();
SELECT current_setting('server_version_num') AS server_version_num;
SELECT xml_is_well_formed_document('<employee><id>1</id></employee>') AS xml_document_is_well_formed;

\echo 'Enable PL/Python and inspect the Python XML runtime'
CREATE EXTENSION IF NOT EXISTS plpython3u;

CREATE OR REPLACE FUNCTION public.xml_runtime_probe()
RETURNS jsonb
LANGUAGE plpython3u
AS $$
import json
import sys
import lxml.etree as etree

return json.dumps({
    "python": sys.version.split()[0],
    "lxml": ".".join(map(str, etree.LXML_VERSION)),
    "libxml2": ".".join(map(str, etree.LIBXML_VERSION)),
})
$$;

SELECT public.xml_runtime_probe();
DROP FUNCTION public.xml_runtime_probe();
