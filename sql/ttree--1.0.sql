
--\echo Usa "CREATE EXTENSION ttree" para cargar esta extensión.\quit

CREATE FUNCTION tthandler(internal)
RETURNS index_am_handler
AS 'MODULE_PATHNAME'
LANGUAGE C;

CREATE ACCESS METHOD ttree TYPE INDEX HANDLER tthandler;
COMMENT ON ACCESS METHOD ttree IS 'T-Tree (claves int4)';


CREATE OPERATOR CLASS int4_ops
DEFAULT FOR TYPE int4 USING ttree AS
    OPERATOR 1 <  (int4, int4),
    OPERATOR 2 <= (int4, int4),
    OPERATOR 3 =  (int4, int4),
    OPERATOR 4 >= (int4, int4),
    OPERATOR 5 >  (int4, int4),
    FUNCTION 1 btint4cmp(int4, int4);







CREATE FUNCTION ttree_lookup(idx regclass, lo int4, hi int4)
RETURNS TABLE (key int4, tid tid)
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;


CREATE FUNCTION ttree_dump(idx regclass)
RETURNS TABLE (blk int4, nkeys int4, height int4, left_blk int8, right_blk int8,
               pos int4, key int4, tid tid)
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;


CREATE FUNCTION ttree_check(idx regclass)
RETURNS text
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;
