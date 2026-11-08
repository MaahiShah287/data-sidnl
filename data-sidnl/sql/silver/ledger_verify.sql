select version, name, length(array_to_string(statements, E'\n')) len,
       md5(array_to_string(statements, E'\n')) exact_md5,
       md5(btrim(regexp_replace(regexp_replace(array_to_string(statements, E'\n'), '[ \t]*--[^\n]*', '', 'g'), '\s+', ' ', 'g'))) comments_stripped_md5
from supabase_migrations.schema_migrations order by version;
