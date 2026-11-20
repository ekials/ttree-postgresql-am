
#include "postgres.h"
#include "access/amapi.h"
#include "access/skey.h"
#include "access/generic_xlog.h"
#include "access/genam.h"
#include "access/tableam.h"
#include "catalog/index.h"
#include "catalog/pg_class.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "nodes/execnodes.h"
#include "pgstat.h"
#include "storage/bufmgr.h"
#include "storage/itemptr.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/selfuncs.h"
#include "utils/tuplestore.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(tthandler);
PG_FUNCTION_INFO_V1(ttree_lookup);
PG_FUNCTION_INFO_V1(ttree_dump);
PG_FUNCTION_INFO_V1(ttree_check);

#define TT_MAGIC       0x54545245   
#define TT_META_BLKNO  0

#ifndef TT_MAX_KEYS
#define TT_MAX_KEYS    4
#endif
#define TT_NO_BLOCK    InvalidBlockNumber

typedef struct TtEntry
{
	int32			key;
	ItemPointerData tid;			
} TtEntry;

typedef struct TtNode
{
	uint16		nkeys;
	int16		height;
	BlockNumber left;
	BlockNumber right;
	TtEntry		e[TT_MAX_KEYS];		
} TtNode;

StaticAssertDecl(sizeof(TtNode) <= BLCKSZ - MAXALIGN(SizeOfPageHeaderData),
				 "TT_MAX_KEYS demasiado grande: el nodo no cabe en una pagina");

typedef struct TtMeta
{
	uint32		magic;
	BlockNumber root;
	uint64		nentries;			
	uint32		nnodes;
} TtMeta;

typedef struct TtCtx
{
	Relation	idx;
	uint32		nnodes_added;
} TtCtx;

typedef void (*TtEmit) (void *arg, const TtEntry *e);


static IndexBuildResult *ttbuild(Relation heap, Relation index, IndexInfo *indexInfo);



static void
tt_set_lower(Page page, Size len)
{
	
	((PageHeader) page)->pd_lower = (char *) PageGetContents(page) + len - (char *) page;
}


static void
tt_get_node(Relation idx, BlockNumber blk, TtNode *out)
{
	Buffer		buf = ReadBuffer(idx, blk);

	LockBuffer(buf, BUFFER_LOCK_SHARE);
	memcpy(out, PageGetContents(BufferGetPage(buf)), sizeof(TtNode));
	UnlockReleaseBuffer(buf);

	if (out->nkeys < 1 || out->nkeys > TT_MAX_KEYS)
		ereport(ERROR,
				(errcode(ERRCODE_INDEX_CORRUPTED),
				 errmsg("ttree: nodo corrupto en bloque %u de \"%s\" (nkeys=%d)",
						blk, RelationGetRelationName(idx), out->nkeys)));
}


static void
tt_put_node(Relation idx, BlockNumber blk, const TtNode *n)
{
	Buffer			buf = ReadBuffer(idx, blk);
	GenericXLogState *st;
	Page			page;

	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	st = GenericXLogStart(idx);
	page = GenericXLogRegisterBuffer(st, buf, 0);
	memcpy(PageGetContents(page), n, sizeof(TtNode));
	tt_set_lower(page, sizeof(TtNode));
	GenericXLogFinish(st);
	UnlockReleaseBuffer(buf);
}


static BlockNumber
tt_new_page(Relation idx, const void *data, Size len)
{
	Buffer			buf = ExtendBufferedRel(BMR_REL(idx), MAIN_FORKNUM, NULL, EB_LOCK_FIRST);
	BlockNumber		blk = BufferGetBlockNumber(buf);
	GenericXLogState *st = GenericXLogStart(idx);
	Page			page = GenericXLogRegisterBuffer(st, buf, GENERIC_XLOG_FULL_IMAGE);

	PageInit(page, BufferGetPageSize(buf), 0);
	memcpy(PageGetContents(page), data, len);
	tt_set_lower(page, len);
	GenericXLogFinish(st);
	UnlockReleaseBuffer(buf);
	return blk;
}


static Buffer
tt_meta_lock(Relation idx, int mode, TtMeta *m)
{
	Buffer		buf = ReadBuffer(idx, TT_META_BLKNO);

	LockBuffer(buf, mode);
	memcpy(m, PageGetContents(BufferGetPage(buf)), sizeof(TtMeta));
	if (m->magic != TT_MAGIC)
		ereport(ERROR,
				(errcode(ERRCODE_INDEX_CORRUPTED),
				 errmsg("ttree: \"%s\" no es un indice ttree valido",
						RelationGetRelationName(idx))));
	return buf;
}


static void
tt_write_meta(Relation idx, Buffer buf, const TtMeta *m)
{
	GenericXLogState *st = GenericXLogStart(idx);
	Page		page = GenericXLogRegisterBuffer(st, buf, 0);

	memcpy(PageGetContents(page), m, sizeof(TtMeta));
	tt_set_lower(page, sizeof(TtMeta));
	GenericXLogFinish(st);
}



static int
tt_height_of(TtCtx *c, BlockNumber blk)
{
	TtNode		n;

	if (blk == TT_NO_BLOCK)
		return 0;
	tt_get_node(c->idx, blk, &n);
	return n.height;
}

static BlockNumber
tt_rot_right(TtCtx *c, BlockNumber yblk, TtNode *y)
{
	BlockNumber xblk = y->left;
	TtNode		x;
	BlockNumber T;

	tt_get_node(c->idx, xblk, &x);
	T = x.right;
	x.right = yblk;
	y->left = T;

	y->height = 1 + Max(tt_height_of(c, y->left), tt_height_of(c, y->right));
	tt_put_node(c->idx, yblk, y);
	x.height = 1 + Max(tt_height_of(c, x.left), y->height);
	tt_put_node(c->idx, xblk, &x);
	return xblk;
}

static BlockNumber
tt_rot_left(TtCtx *c, BlockNumber xblk, TtNode *x)
{
	BlockNumber yblk = x->right;
	TtNode		y;
	BlockNumber T;

	tt_get_node(c->idx, yblk, &y);
	T = y.left;
	y.left = xblk;
	x->right = T;

	x->height = 1 + Max(tt_height_of(c, x->left), tt_height_of(c, x->right));
	tt_put_node(c->idx, xblk, x);
	y.height = 1 + Max(x->height, tt_height_of(c, y.right));
	tt_put_node(c->idx, yblk, &y);
	return yblk;
}


static BlockNumber
tt_rebalance(TtCtx *c, BlockNumber blk, TtNode *n)
{
	int			hl = tt_height_of(c, n->left);
	int			hr = tt_height_of(c, n->right);
	int			b = hl - hr;

	n->height = 1 + Max(hl, hr);

	if (b > 1)
	{
		TtNode		l;

		tt_get_node(c->idx, n->left, &l);
		if (tt_height_of(c, l.left) - tt_height_of(c, l.right) < 0)
			n->left = tt_rot_left(c, n->left, &l);
		return tt_rot_right(c, blk, n);
	}
	if (b < -1)
	{
		TtNode		r;

		tt_get_node(c->idx, n->right, &r);
		if (tt_height_of(c, r.left) - tt_height_of(c, r.right) > 0)
			n->right = tt_rot_right(c, n->right, &r);
		return tt_rot_left(c, blk, n);
	}
	tt_put_node(c->idx, blk, n);
	return blk;
}



static BlockNumber
tt_insert_rec(TtCtx *c, BlockNumber blk, TtEntry ent)
{
	TtNode		n;
	int			i;

	check_stack_depth();

	if (blk == TT_NO_BLOCK)
	{
		memset(&n, 0, sizeof(n));
		n.nkeys = 1;
		n.height = 1;
		n.left = n.right = TT_NO_BLOCK;
		n.e[0] = ent;
		c->nnodes_added++;
		return tt_new_page(c->idx, &n, sizeof(n));
	}

	tt_get_node(c->idx, blk, &n);

	if (ent.key < n.e[0].key && n.left != TT_NO_BLOCK)
		n.left = tt_insert_rec(c, n.left, ent);
	else if (ent.key > n.e[n.nkeys - 1].key && n.right != TT_NO_BLOCK)
		n.right = tt_insert_rec(c, n.right, ent);
	else
	{
		
		i = 0;
		while (i < n.nkeys && n.e[i].key <= ent.key)
			i++;

		if (n.nkeys >= TT_MAX_KEYS)
		{
			TtEntry		ev;

			if (i == 0)
			{
				
				ev = n.e[n.nkeys - 1];
				memmove(&n.e[1], &n.e[0], (n.nkeys - 1) * sizeof(TtEntry));
				n.e[0] = ent;
				n.right = tt_insert_rec(c, n.right, ev);
			}
			else
			{
				
				TtEntry		tmp[TT_MAX_KEYS + 1];

				memcpy(tmp, n.e, i * sizeof(TtEntry));
				tmp[i] = ent;
				memcpy(&tmp[i + 1], &n.e[i], (n.nkeys - i) * sizeof(TtEntry));
				ev = tmp[0];
				memcpy(n.e, &tmp[1], TT_MAX_KEYS * sizeof(TtEntry));
				n.left = tt_insert_rec(c, n.left, ev);
			}
		}
		else
		{
			memmove(&n.e[i + 1], &n.e[i], (n.nkeys - i) * sizeof(TtEntry));
			n.e[i] = ent;
			n.nkeys++;
		}
	}

	return tt_rebalance(c, blk, &n);
}

static void
tt_insert_key(Relation idx, int32 key, ItemPointer tid)
{
	TtMeta		m;
	Buffer		mb = tt_meta_lock(idx, BUFFER_LOCK_EXCLUSIVE, &m);
	TtCtx		c;
	TtEntry		e;

	c.idx = idx;
	c.nnodes_added = 0;
	e.key = key;
	e.tid = *tid;

	m.root = tt_insert_rec(&c, m.root, e);
	m.nentries++;
	m.nnodes += c.nnodes_added;
	tt_write_meta(idx, mb, &m);
	UnlockReleaseBuffer(mb);
}



static void
tt_range_rec(Relation idx, BlockNumber blk, int32 lo, int32 hi, TtEmit emit, void *arg)
{
	TtNode		n;
	int			i;

	if (blk == TT_NO_BLOCK)
		return;
	check_stack_depth();
	tt_get_node(idx, blk, &n);

	if (lo <= n.e[0].key)
		tt_range_rec(idx, n.left, lo, hi, emit, arg);
	for (i = 0; i < n.nkeys; i++)
		if (n.e[i].key >= lo && n.e[i].key <= hi)
			emit(arg, &n.e[i]);
	if (hi >= n.e[n.nkeys - 1].key)
		tt_range_rec(idx, n.right, lo, hi, emit, arg);
}



typedef struct TtBuildState
{
	TtEntry	   *ents;
	int64		n;
	int64		cap;
} TtBuildState;

static void
tt_build_cb(Relation index, ItemPointer tid, Datum *values, bool *isnull,
			bool tupleIsAlive, void *state)
{
	TtBuildState *st = (TtBuildState *) state;

	if (isnull[0])
		return;
	if (st->n >= st->cap)
	{
		st->cap *= 2;
		st->ents = (TtEntry *) repalloc_huge(st->ents, st->cap * sizeof(TtEntry));
	}
	st->ents[st->n].key = DatumGetInt32(values[0]);
	st->ents[st->n].tid = *tid;
	st->n++;
}

static int
tt_entry_cmp(const void *a, const void *b)
{
	const TtEntry *x = (const TtEntry *) a;
	const TtEntry *y = (const TtEntry *) b;

	if (x->key != y->key)
		return (x->key < y->key) ? -1 : 1;
	return ItemPointerCompare((ItemPointer) &x->tid, (ItemPointer) &y->tid);
}


static BlockNumber
tt_bulk(TtCtx *c, TtEntry *ents, int64 n, int64 lo, int64 hi, int *h)
{
	int64		mid, start, cnt;
	int			hl, hr;
	BlockNumber l, r;
	TtNode		node;

	if (lo > hi)
	{
		*h = 0;
		return TT_NO_BLOCK;
	}
	check_stack_depth();
	mid = lo + (hi - lo) / 2;
	l = tt_bulk(c, ents, n, lo, mid - 1, &hl);
	r = tt_bulk(c, ents, n, mid + 1, hi, &hr);

	start = mid * TT_MAX_KEYS;
	cnt = Min((int64) TT_MAX_KEYS, n - start);

	memset(&node, 0, sizeof(node));
	node.nkeys = (uint16) cnt;
	node.height = (int16) (1 + Max(hl, hr));
	node.left = l;
	node.right = r;
	memcpy(node.e, &ents[start], cnt * sizeof(TtEntry));
	c->nnodes_added++;
	*h = node.height;
	return tt_new_page(c->idx, &node, sizeof(node));
}

static IndexBuildResult *
ttbuild(Relation heap, Relation index, IndexInfo *indexInfo)
{
	IndexBuildResult *result;
	TtBuildState st;
	TtCtx		c;
	TtMeta		m;
	Buffer		mb;
	double		reltuples;
	int64		nblocks;
	int			h;

	if (RelationGetNumberOfBlocks(index) != 0)
		elog(ERROR, "el indice \"%s\" ya contiene datos", RelationGetRelationName(index));

	
	memset(&m, 0, sizeof(m));
	m.magic = TT_MAGIC;
	m.root = TT_NO_BLOCK;
	if (tt_new_page(index, &m, sizeof(m)) != TT_META_BLKNO)
		elog(ERROR, "ttree: la metapagina no quedo en el bloque 0");

	st.n = 0;
	st.cap = 1024;
	st.ents = (TtEntry *) MemoryContextAllocHuge(CurrentMemoryContext, st.cap * sizeof(TtEntry));

	reltuples = table_index_build_scan(heap, index, indexInfo, true, true,
									   tt_build_cb, (void *) &st, NULL);

	if (st.n > 1)
		qsort(st.ents, st.n, sizeof(TtEntry), tt_entry_cmp);

	c.idx = index;
	c.nnodes_added = 0;
	nblocks = (st.n + TT_MAX_KEYS - 1) / TT_MAX_KEYS;
	m.root = tt_bulk(&c, st.ents, st.n, 0, nblocks - 1, &h);
	m.nentries = st.n;
	m.nnodes = c.nnodes_added;

	mb = ReadBuffer(index, TT_META_BLKNO);
	LockBuffer(mb, BUFFER_LOCK_EXCLUSIVE);
	tt_write_meta(index, mb, &m);
	UnlockReleaseBuffer(mb);

	result = (IndexBuildResult *) palloc(sizeof(IndexBuildResult));
	result->heap_tuples = reltuples;
	result->index_tuples = (double) st.n;
	pfree(st.ents);
	return result;
}

static void
ttbuildempty(Relation index)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("ttree: no se soportan indices sobre tablas UNLOGGED")));
}



static bool
ttinsert(Relation index, Datum *values, bool *isnull, ItemPointer ht_ctid,
		 Relation heapRel, IndexUniqueCheck checkUnique, bool indexUnchanged,
		 IndexInfo *indexInfo)
{
	if (isnull[0])
		return false;
	tt_insert_key(index, DatumGetInt32(values[0]), ht_ctid);
	return false;
}



static IndexBulkDeleteResult *
ttbulkdelete(IndexVacuumInfo *info, IndexBulkDeleteResult *stats,
			 IndexBulkDeleteCallback callback, void *callback_state)
{
	Relation	idx = info->index;
	TtMeta		m;
	Buffer		mb;
	BlockNumber nblocks, blk;

	if (stats == NULL)
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));
	/* cada pasada recorre el indice completo: el conteo de vivas no se acumula entre pasadas */
	stats->num_index_tuples = 0;

	mb = tt_meta_lock(idx, BUFFER_LOCK_EXCLUSIVE, &m);
	nblocks = RelationGetNumberOfBlocks(idx);

	for (blk = 1; blk < nblocks; blk++)
	{
		TtNode		n;
		bool		dirty = false;
		int			i;

		CHECK_FOR_INTERRUPTS();
		tt_get_node(idx, blk, &n);
		for (i = 0; i < n.nkeys; i++)
		{
			if (!ItemPointerIsValid(&n.e[i].tid))
				continue;
			if (callback(&n.e[i].tid, callback_state))
			{
				ItemPointerSetInvalid(&n.e[i].tid);
				stats->tuples_removed += 1;
				dirty = true;
			}
			else
				stats->num_index_tuples += 1;
		}
		if (dirty)
			tt_put_node(idx, blk, &n);
	}
	UnlockReleaseBuffer(mb);
	return stats;
}

static IndexBulkDeleteResult *
ttvacuumcleanup(IndexVacuumInfo *info, IndexBulkDeleteResult *stats)
{
	if (info->analyze_only)
		return stats;
	if (stats == NULL)
	{
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));
		stats->estimated_count = true;
		stats->num_index_tuples = info->num_heap_tuples;
	}
	stats->num_pages = RelationGetNumberOfBlocks(info->index);
	return stats;
}



typedef struct TtScanState
{
	Relation	index;
	TtEntry	   *entries;
	int64		nentries;
	int64		current;
	int64		capacity;
	bool		initialized;
	bool		empty;
} TtScanState;

static void
tt_scan_emit(void *arg, const TtEntry *e)
{
	TtScanState *st = (TtScanState *) arg;

	
	if (!ItemPointerIsValid(&e->tid))
		return;

	if (st->nentries >= st->capacity)
	{
		if (st->capacity == 0)
		{
			st->capacity = 64;
			st->entries = (TtEntry *) palloc(st->capacity * sizeof(TtEntry));
		}
		else
		{
			st->capacity *= 2;
			st->entries = (TtEntry *) repalloc(st->entries,
											st->capacity * sizeof(TtEntry));
		}
	}

	st->entries[st->nentries++] = *e;
}

static void
tt_scan_prepare(IndexScanDesc scan, TtScanState *st)
{
	int64		lo = PG_INT32_MIN;
	int64		hi = PG_INT32_MAX;
	int			i;
	bool		impossible = false;
	TtMeta		m;
	Buffer		mb;

	if (st->initialized)
		return;

	st->index = scan->indexRelation;
	st->nentries = 0;
	st->current = 0;
	st->capacity = 0;
	st->entries = NULL;
	st->empty = false;

	for (i = 0; i < scan->numberOfKeys; i++)
	{
		ScanKey key = &scan->keyData[i];
		int32	value;
		int64	v;

		
		if (key->sk_attno != 1)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("ttree: solo se soporta la primera columna del indice")));

		
		if (key->sk_flags & (SK_ISNULL | SK_SEARCHNULL | SK_SEARCHNOTNULL |
									 SK_SEARCHARRAY | SK_ROW_HEADER | SK_ROW_MEMBER))
		{
			impossible = true;
			break;
		}

		value = DatumGetInt32(key->sk_argument);
		v = (int64) value;

		switch (key->sk_strategy)
		{
			case BTLessStrategyNumber:
				if (v <= PG_INT32_MIN)
					impossible = true;
				else
					hi = Min(hi, v - 1);
				break;

			case BTLessEqualStrategyNumber:
				hi = Min(hi, v);
				break;

			case BTEqualStrategyNumber:
				lo = Max(lo, v);
				hi = Min(hi, v);
				break;

			case BTGreaterEqualStrategyNumber:
				lo = Max(lo, v);
				break;

			case BTGreaterStrategyNumber:
				if (v >= PG_INT32_MAX)
					impossible = true;
				else
					lo = Max(lo, v + 1);
				break;

			default:
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("ttree: estrategia de busqueda %u no soportada",
								key->sk_strategy)));
		}
	}

	if (impossible || lo > hi)
	{
		st->empty = true;
		st->initialized = true;
		return;
	}

	pgstat_count_index_scan(st->index);
	if (scan->instrument)
		scan->instrument->nsearches++;

	mb = tt_meta_lock(st->index, BUFFER_LOCK_SHARE, &m);
	tt_range_rec(st->index, m.root, (int32) lo, (int32) hi,
				 tt_scan_emit, st);
	UnlockReleaseBuffer(mb);

	st->empty = (st->nentries == 0);
	st->initialized = true;
}

static IndexScanDesc
ttbeginscan(Relation r, int nkeys, int norderbys)
{
	IndexScanDesc scan;
	TtScanState *st;

	if (norderbys != 0)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("ttree: ORDER BY no esta implementado")));

	scan = RelationGetIndexScan(r, nkeys, norderbys);
	st = (TtScanState *) palloc0(sizeof(TtScanState));
	st->index = r;
	scan->opaque = st;

	return scan;
}

static bool
ttgettuple(IndexScanDesc scan, ScanDirection direction)
{
	TtScanState *st = (TtScanState *) scan->opaque;

	
	if (direction != ForwardScanDirection)
		return false;

	tt_scan_prepare(scan, st);

	if (st->empty || st->current >= st->nentries)
		return false;

	scan->xs_heaptid = st->entries[st->current].tid;
	scan->xs_recheck = false;
	st->current++;

	return true;
}

static void
ttrescan(IndexScanDesc scan, ScanKey scankey, int nscankeys,
			 ScanKey orderbys, int norderbys)
{
	TtScanState *st = (TtScanState *) scan->opaque;

	if (norderbys != 0)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("ttree: ORDER BY no esta implementado")));

	if (scankey && nscankeys > 0)
		memcpy(scan->keyData, scankey, nscankeys * sizeof(ScanKeyData));

	if (st->entries != NULL)
	{
		pfree(st->entries);
		st->entries = NULL;
	}
	st->nentries = 0;
	st->current = 0;
	st->capacity = 0;
	st->initialized = false;
	st->empty = false;
}

static void
ttendscan(IndexScanDesc scan)
{
	TtScanState *st = (TtScanState *) scan->opaque;

	if (st != NULL)
	{
		if (st->entries != NULL)
			pfree(st->entries);
		pfree(st);
		scan->opaque = NULL;
	}
}

static void
ttcostestimate(PlannerInfo *root, IndexPath *path, double loop_count,
			   Cost *indexStartupCost, Cost *indexTotalCost,
			   Selectivity *indexSelectivity, double *indexCorrelation,
			   double *indexPages)
{
	GenericCosts costs;

	MemSet(&costs, 0, sizeof(costs));
	genericcostestimate(root, path, loop_count, &costs);
	*indexStartupCost = costs.indexStartupCost;
	*indexTotalCost = costs.indexTotalCost;
	*indexSelectivity = costs.indexSelectivity;
	*indexCorrelation = costs.indexCorrelation;
	*indexPages = costs.numIndexPages;
}

static bool
ttvalidate(Oid opclassoid)
{
	return true;
}

Datum
tthandler(PG_FUNCTION_ARGS)
{
	IndexAmRoutine *amroutine = makeNode(IndexAmRoutine);	

	amroutine->amstrategies = 5;		
	amroutine->amsupport = 1;			
	amroutine->amoptsprocnum = 0;
	/* los NULL no se indexan: el planner no debe usar el indice sin condicion sobre la clave */
	amroutine->amoptionalkey = false;
	amroutine->amkeytype = InvalidOid;

	amroutine->ambuild = ttbuild;
	amroutine->ambuildempty = ttbuildempty;
	amroutine->aminsert = ttinsert;
	amroutine->ambulkdelete = ttbulkdelete;
	amroutine->amvacuumcleanup = ttvacuumcleanup;
	amroutine->amcostestimate = ttcostestimate;
	amroutine->amvalidate = ttvalidate;
	amroutine->ambeginscan = ttbeginscan;
	amroutine->amrescan = ttrescan;
	amroutine->amgettuple = ttgettuple;
	amroutine->amgetbitmap = NULL;
	amroutine->amendscan = ttendscan;

	PG_RETURN_POINTER(amroutine);
}



static Relation
tt_open(Oid oid)
{
	Relation	r = index_open(oid, AccessShareLock);

	if (r->rd_rel->relkind != RELKIND_INDEX || r->rd_indam->ambuild != ttbuild)
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("\"%s\" no es un indice ttree", RelationGetRelationName(r))));
	return r;
}

static void
tt_emit_lookup(void *arg, const TtEntry *e)
{
	ReturnSetInfo *rsi = (ReturnSetInfo *) arg;
	Datum		v[2];
	bool		nl[2] = {false, false};

	if (!ItemPointerIsValid(&e->tid))
		return;						
	v[0] = Int32GetDatum(e->key);
	v[1] = ItemPointerGetDatum(&e->tid);
	tuplestore_putvalues(rsi->setResult, rsi->setDesc, v, nl);
}


Datum
ttree_lookup(PG_FUNCTION_ARGS)
{
	Oid			idxoid = PG_GETARG_OID(0);
	int32		lo = PG_GETARG_INT32(1);
	int32		hi = PG_GETARG_INT32(2);
	ReturnSetInfo *rsi = (ReturnSetInfo *) fcinfo->resultinfo;
	Relation	idx;
	TtMeta		m;
	Buffer		mb;

	InitMaterializedSRF(fcinfo, 0);
	idx = tt_open(idxoid);
	mb = tt_meta_lock(idx, BUFFER_LOCK_SHARE, &m);
	tt_range_rec(idx, m.root, lo, hi, tt_emit_lookup, rsi);
	UnlockReleaseBuffer(mb);
	index_close(idx, AccessShareLock);
	return (Datum) 0;
}

static void
tt_dump_rec(Relation idx, BlockNumber blk, ReturnSetInfo *rsi)
{
	TtNode		n;
	int			i;

	if (blk == TT_NO_BLOCK)
		return;
	check_stack_depth();
	tt_get_node(idx, blk, &n);

	tt_dump_rec(idx, n.left, rsi);
	for (i = 0; i < n.nkeys; i++)
	{
		Datum		v[8];
		bool		nl[8];

		memset(nl, 0, sizeof(nl));
		v[0] = Int32GetDatum((int32) blk);
		v[1] = Int32GetDatum(n.nkeys);
		v[2] = Int32GetDatum(n.height);
		v[3] = Int64GetDatum(n.left);
		nl[3] = (n.left == TT_NO_BLOCK);
		v[4] = Int64GetDatum(n.right);
		nl[4] = (n.right == TT_NO_BLOCK);
		v[5] = Int32GetDatum(i);
		v[6] = Int32GetDatum(n.e[i].key);
		v[7] = ItemPointerGetDatum(&n.e[i].tid);
		nl[7] = !ItemPointerIsValid(&n.e[i].tid);
		tuplestore_putvalues(rsi->setResult, rsi->setDesc, v, nl);
	}
	tt_dump_rec(idx, n.right, rsi);
}


Datum
ttree_dump(PG_FUNCTION_ARGS)
{
	Oid			idxoid = PG_GETARG_OID(0);
	ReturnSetInfo *rsi = (ReturnSetInfo *) fcinfo->resultinfo;
	Relation	idx;
	TtMeta		m;
	Buffer		mb;

	InitMaterializedSRF(fcinfo, 0);
	idx = tt_open(idxoid);
	mb = tt_meta_lock(idx, BUFFER_LOCK_SHARE, &m);
	tt_dump_rec(idx, m.root, rsi);
	UnlockReleaseBuffer(mb);
	index_close(idx, AccessShareLock);
	return (Datum) 0;
}

typedef struct TtChk
{
	Relation	idx;
	BlockNumber nblocks;
	uint32		nodes;
	int64		entries;
	int64		tombstones;
	bool		have_prev;
	int32		prev;
	char		err[256];
} TtChk;

static int
tt_check_rec(TtChk *k, BlockNumber blk)
{
	TtNode		n;
	int			hl, hr, i;

	if (blk == TT_NO_BLOCK || k->err[0])
		return 0;
	check_stack_depth();

	if (blk >= k->nblocks || blk == TT_META_BLKNO)
	{
		snprintf(k->err, sizeof(k->err), "puntero a bloque invalido: %u", blk);
		return 0;
	}
	if (++k->nodes > k->nblocks)
	{
		snprintf(k->err, sizeof(k->err), "ciclo detectado en el arbol");
		return 0;
	}
	tt_get_node(k->idx, blk, &n);

	hl = tt_check_rec(k, n.left);
	for (i = 0; i < n.nkeys && !k->err[0]; i++)
	{
		if (k->have_prev && n.e[i].key < k->prev)
			snprintf(k->err, sizeof(k->err),
					 "orden violado en bloque %u pos %d: %d despues de %d",
					 blk, i, n.e[i].key, k->prev);
		k->prev = n.e[i].key;
		k->have_prev = true;
		k->entries++;
		if (!ItemPointerIsValid(&n.e[i].tid))
			k->tombstones++;
	}
	hr = tt_check_rec(k, n.right);

	if (!k->err[0] && n.height != 1 + Max(hl, hr))
		snprintf(k->err, sizeof(k->err), "altura incorrecta en bloque %u: guardada %d, real %d",
				 blk, n.height, 1 + Max(hl, hr));
	if (!k->err[0] && abs(hl - hr) > 1)
		snprintf(k->err, sizeof(k->err), "desbalance en bloque %u: hl=%d hr=%d", blk, hl, hr);
	return 1 + Max(hl, hr);
}


Datum
ttree_check(PG_FUNCTION_ARGS)
{
	Oid			idxoid = PG_GETARG_OID(0);
	Relation	idx = tt_open(idxoid);
	TtMeta		m;
	Buffer		mb = tt_meta_lock(idx, BUFFER_LOCK_SHARE, &m);
	TtChk		k;
	int			h;
	char	   *res;

	memset(&k, 0, sizeof(k));
	k.idx = idx;
	k.nblocks = RelationGetNumberOfBlocks(idx);
	h = tt_check_rec(&k, m.root);

	if (!k.err[0] && k.entries != (int64) m.nentries)
		snprintf(k.err, sizeof(k.err), "entradas recorridas=%lld pero meta dice %llu",
				 (long long) k.entries, (unsigned long long) m.nentries);
	if (!k.err[0] && k.nodes != m.nnodes)
		snprintf(k.err, sizeof(k.err), "nodos recorridos=%u pero meta dice %u", k.nodes, m.nnodes);
	if (!k.err[0] && k.nodes + 1 != k.nblocks)
		snprintf(k.err, sizeof(k.err), "hay paginas huerfanas: %u nodos, %u bloques",
				 k.nodes, k.nblocks);

	if (k.err[0])
		res = psprintf("ERROR: %s", k.err);
	else
		res = psprintf("OK nodos=%u entradas=%lld borradas=%lld altura=%d",
					   k.nodes, (long long) k.entries, (long long) k.tombstones, h);

	UnlockReleaseBuffer(mb);
	index_close(idx, AccessShareLock);
	PG_RETURN_TEXT_P(cstring_to_text(res));
}
