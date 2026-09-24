#include "pgaudix.h"

#include "access/htup_details.h"
#include "catalog/pg_type.h"
#include "commands/trigger.h"
#include "executor/spi.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/hsearch.h"
#include "utils/inval.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(pgaudix_trigger);

/*
 * Per-backend cache of prepared audit INSERT statements, one per source
 * relation (for a partitioned table: one per partition, since each partition
 * has its own tuple descriptor).
 *
 * Without it every audited row pays a full parse/analyze/plan of the INSERT,
 * which costs more than the INSERT itself. The plan is built from the source
 * tuple descriptor and the trigger argument (the audit table name), both of
 * which only change through DDL on the source relation, and any such DDL
 * invalidates the source's relcache entry in every backend. A relcache
 * callback therefore marks the entry stale; it is rebuilt on next use. Stale
 * plans are freed on the next trigger call, not inside the callback (which
 * may run during abort processing) and never while the plan is executing
 * (in_use, for a nested audit trigger fired from within the audit INSERT).
 * Entries of relations that were dropped are swept the same way, so a
 * long-lived connection that churns through partitions does not accumulate
 * plans. Changes to the audit table itself are tracked by PostgreSQL's own
 * plan cache, which replans the saved statement.
 */
typedef struct AuditPlanEntry
{
	Oid			relid;			/* hash key: source relation OID */
	bool		valid;			/* false once relid was invalidated */
	SPIPlanPtr	plan;			/* saved plan (SPI_keepplan), or NULL */
	int			nparams;		/* 1 (operation) + audited columns */
	int			natts;			/* natts of the tupdesc the plan was built for */
	int			in_use;			/* nesting depth of SPI_execute_plan on plan */
} AuditPlanEntry;

static HTAB *audit_plan_cache = NULL;

/* Number of entries marked stale by the callback and not yet swept */
static int	stale_entries = 0;

/*
 * Columns the trigger does not write: dropped columns, and virtual generated
 * columns (PostgreSQL 18+), which carry no stored value. enable()/ddl_sync()
 * still mirror a virtual column in the audit table (it stays NULL) so the
 * attnum alignment survives pg_dump/restore.
 */
static inline bool
skip_attribute(Form_pg_attribute attr)
{
	if (attr->attisdropped)
		return true;
#ifdef ATTRIBUTE_GENERATED_VIRTUAL
	if (attr->attgenerated == ATTRIBUTE_GENERATED_VIRTUAL)
		return true;
#endif
	return false;
}

/*
 * Relcache invalidation callback: mark the entry for relid stale, or all
 * entries when relid is InvalidOid (full cache reset).
 */
static void
audit_plan_cache_callback(Datum arg, Oid relid)
{
	AuditPlanEntry *entry;

	if (audit_plan_cache == NULL)
		return;

	if (OidIsValid(relid))
	{
		entry = (AuditPlanEntry *) hash_search(audit_plan_cache, &relid,
											   HASH_FIND, NULL);
		if (entry != NULL && entry->valid)
		{
			entry->valid = false;
			stale_entries++;
		}
	}
	else
	{
		HASH_SEQ_STATUS status;

		hash_seq_init(&status, audit_plan_cache);
		while ((entry = (AuditPlanEntry *) hash_seq_search(&status)) != NULL)
		{
			if (entry->valid)
			{
				entry->valid = false;
				stale_entries++;
			}
		}
	}
}

/*
 * Free and remove every stale entry that is not executing right now, except
 * the one for keep_relid (its caller rebuilds it in place). Safe to call only
 * from the trigger, never from the invalidation callback.
 */
static void
sweep_stale_plans(Oid keep_relid)
{
	HASH_SEQ_STATUS status;
	AuditPlanEntry *entry;
	int			remaining = 0;

	hash_seq_init(&status, audit_plan_cache);
	while ((entry = (AuditPlanEntry *) hash_seq_search(&status)) != NULL)
	{
		if (entry->valid)
			continue;
		if (entry->in_use > 0 || entry->relid == keep_relid)
		{
			remaining++;
			continue;
		}
		if (entry->plan != NULL)
			SPI_freeplan(entry->plan);
		/* dynahash allows removing the entry just returned by the scan */
		hash_search(audit_plan_cache, &entry->relid, HASH_REMOVE, NULL);
	}
	stale_entries = remaining;
}

void
_PG_init(void)
{
	HASHCTL		ctl;

	memset(&ctl, 0, sizeof(ctl));
	ctl.keysize = sizeof(Oid);
	ctl.entrysize = sizeof(AuditPlanEntry);
	ctl.hcxt = TopMemoryContext;
	audit_plan_cache = hash_create("pgaudix audit plan cache", 16, &ctl,
								   HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

	CacheRegisterRelcacheCallback(audit_plan_cache_callback, (Datum) 0);
}

/*
 * Return the cached INSERT plan for the source relation, building it if the
 * cache has no valid entry. Must be called with SPI connected.
 *
 * The statement is:
 *   INSERT INTO "schema"."table_audit" (audit_operation, col1, ...)
 *   VALUES ($1, $2, ...)
 * with $1 = operation (text) and one parameter per audited source column,
 * typed with the source column's type.
 */
static AuditPlanEntry *
get_audit_plan(Oid relid, TupleDesc tupdesc, const char *audit_table)
{
	AuditPlanEntry *entry;
	bool		found;
	StringInfoData cols;
	StringInfoData vals;
	StringInfoData query;
	Oid		   *argtypes;
	int			natts = tupdesc->natts;
	int			nparams;
	int			paramidx;
	int			i;

	if (stale_entries > 0)
		sweep_stale_plans(relid);

	entry = (AuditPlanEntry *) hash_search(audit_plan_cache, &relid,
										   HASH_ENTER, &found);
	if (!found)
	{
		entry->valid = false;
		entry->plan = NULL;
		entry->nparams = 0;
		entry->natts = 0;
		entry->in_use = 0;
	}

	if (entry->valid && entry->plan != NULL && entry->natts == natts)
		return entry;

	/*
	 * Stale or new: drop the old plan (outside the invalidation callback).
	 * A stale plan that is still executing (this trigger fired from inside
	 * its own audit INSERT) cannot be replaced in place.
	 */
	if (entry->in_use > 0)
		elog(ERROR, "pgaudix: audit plan for relation %u is stale while in use",
			 relid);
	entry->valid = false;
	if (entry->plan != NULL)
	{
		SPI_freeplan(entry->plan);
		entry->plan = NULL;
	}

	/* Count audited columns */
	nparams = 1;
	for (i = 0; i < natts; i++)
	{
		if (!skip_attribute(TupleDescAttr(tupdesc, i)))
			nparams++;
	}

	argtypes = (Oid *) palloc(nparams * sizeof(Oid));
	initStringInfo(&cols);
	initStringInfo(&vals);

	argtypes[0] = TEXTOID;
	appendStringInfoString(&cols, "audit_operation");
	appendStringInfoString(&vals, "$1");

	paramidx = 1;
	for (i = 0; i < natts; i++)
	{
		Form_pg_attribute attr = TupleDescAttr(tupdesc, i);

		if (skip_attribute(attr))
			continue;

		appendStringInfo(&cols, ", %s", quote_identifier(NameStr(attr->attname)));
		appendStringInfo(&vals, ", $%d", paramidx + 1);
		argtypes[paramidx] = attr->atttypid;
		paramidx++;
	}

	initStringInfo(&query);
	appendStringInfo(&query, "INSERT INTO %s (%s) VALUES (%s)",
					 audit_table, cols.data, vals.data);

	entry->plan = SPI_prepare(query.data, nparams, argtypes);
	if (entry->plan == NULL)
		elog(ERROR, "pgaudix: SPI_prepare failed: %s",
			 SPI_result_code_string(SPI_result));
	if (SPI_keepplan(entry->plan) != 0)
		elog(ERROR, "pgaudix: SPI_keepplan failed");

	entry->nparams = nparams;
	entry->natts = natts;
	entry->valid = true;

	pfree(cols.data);
	pfree(vals.data);
	pfree(query.data);
	pfree(argtypes);

	return entry;
}

/*
 * Insert one audit row into the audit table.
 *
 * operation: one of "I", "U", "D"
 * tuple: the row data to record
 * relid/tupdesc: the source relation and its tuple descriptor
 * audit_table: fully qualified audit table name (already quoted)
 */
static void
insert_audit_row(const char *operation, HeapTuple tuple, Oid relid,
				 TupleDesc tupdesc, const char *audit_table)
{
	AuditPlanEntry *entry;
	int			natts = tupdesc->natts;
	Datum	   *values;
	char	   *nulls;
	int			paramidx;
	int			i;
	int			ret;

	entry = get_audit_plan(relid, tupdesc, audit_table);

	/* palloc never returns NULL — it ereports on OOM */
	values = (Datum *) palloc(entry->nparams * sizeof(Datum));
	nulls = (char *) palloc(entry->nparams * sizeof(char));

	/* $1 = audit_operation */
	values[0] = CStringGetTextDatum(operation);
	nulls[0] = ' ';

	/* Data columns from the tuple, in the order the plan was built */
	paramidx = 1;
	for (i = 0; i < natts; i++)
	{
		Form_pg_attribute attr = TupleDescAttr(tupdesc, i);
		bool		isnull;
		Datum		val;

		if (skip_attribute(attr))
			continue;

		if (paramidx >= entry->nparams)
			elog(ERROR, "pgaudix: cached plan does not match the tuple descriptor");

		val = heap_getattr(tuple, attr->attnum, tupdesc, &isnull);

		if (isnull)
		{
			values[paramidx] = (Datum) 0;
			nulls[paramidx] = 'n';
		}
		else
		{
			values[paramidx] = val;
			nulls[paramidx] = ' ';
		}

		paramidx++;
	}

	if (paramidx != entry->nparams)
		elog(ERROR, "pgaudix: cached plan does not match the tuple descriptor");

	entry->in_use++;
	PG_TRY();
	{
		ret = SPI_execute_plan(entry->plan, values, nulls, false, 0);
	}
	PG_FINALLY();
	{
		entry->in_use--;
	}
	PG_END_TRY();
	if (ret != SPI_OK_INSERT)
		elog(ERROR, "pgaudix: audit INSERT failed (SPI returned %d)", ret);

	pfree(values);
	pfree(nulls);
}

/*
 * pgaudix_trigger - DML audit trigger function.
 *
 * Called as an AFTER ROW trigger. Receives the fully-qualified
 * audit table name as tgargs[0].
 *
 * For INSERT: inserts one row with operation 'I' and NEW values.
 * For DELETE: inserts one row with operation 'D' and OLD values.
 * For UPDATE: inserts one row with operation 'U' and NEW values.
 */
Datum
pgaudix_trigger(PG_FUNCTION_ARGS)
{
	TriggerData *trigdata = (TriggerData *) fcinfo->context;
	TupleDesc	tupdesc;
	Oid			relid;
	const char *audit_table;
	HeapTuple	rettuple;

	/* Verify we are called as a trigger */
	if (!CALLED_AS_TRIGGER(fcinfo))
		elog(ERROR, "pgaudix_trigger: not called by trigger manager");

	/* Must be an AFTER ROW trigger */
	if (!TRIGGER_FIRED_AFTER(trigdata->tg_event))
		elog(ERROR, "pgaudix_trigger: must be fired AFTER");
	if (!TRIGGER_FIRED_FOR_ROW(trigdata->tg_event))
		elog(ERROR, "pgaudix_trigger: must be fired FOR EACH ROW");

	/* Get the audit table name from trigger arguments */
	if (trigdata->tg_trigger->tgnargs < 1)
		elog(ERROR, "pgaudix_trigger: must have audit table name as argument");
	audit_table = trigdata->tg_trigger->tgargs[0];

	/*
	 * Validate the audit table argument looks like a quoted "schema"."table"
	 * identifier. This prevents SQL injection if someone tampers with
	 * pg_trigger.tgargs directly. The enable() function always produces
	 * this form using explicit double-quoting.
	 */
	{
		const char *p = audit_table;

		if (*p != '"')
			elog(ERROR, "pgaudix_trigger: invalid audit table name format");

		/* scan past first quoted identifier (handles "" escape) */
		p++;
		while (*p)
		{
			if (*p == '"')
			{
				if (*(p + 1) == '"')	/* escaped "" */
				{
					p += 2;
					continue;
				}
				break;					/* closing quote */
			}
			p++;
		}
		if (*p != '"')
			elog(ERROR, "pgaudix_trigger: invalid audit table name format");
		p++;

		/* expect a dot separator */
		if (*p != '.')
			elog(ERROR, "pgaudix_trigger: invalid audit table name format");
		p++;

		/* second quoted identifier */
		if (*p != '"')
			elog(ERROR, "pgaudix_trigger: invalid audit table name format");
		p++;
		while (*p)
		{
			if (*p == '"')
			{
				if (*(p + 1) == '"')
				{
					p += 2;
					continue;
				}
				break;
			}
			p++;
		}
		if (*p != '"')
			elog(ERROR, "pgaudix_trigger: invalid audit table name format");
		p++;

		/* must be end of string */
		if (*p != '\0')
			elog(ERROR, "pgaudix_trigger: invalid audit table name format");
	}

	tupdesc = trigdata->tg_relation->rd_att;
	relid = RelationGetRelid(trigdata->tg_relation);

	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "pgaudix_trigger: SPI_connect failed");

	if (TRIGGER_FIRED_BY_INSERT(trigdata->tg_event))
	{
		insert_audit_row(AUDIT_OP_INSERT, trigdata->tg_trigtuple, relid,
						 tupdesc, audit_table);
		rettuple = trigdata->tg_trigtuple;
	}
	else if (TRIGGER_FIRED_BY_DELETE(trigdata->tg_event))
	{
		insert_audit_row(AUDIT_OP_DELETE, trigdata->tg_trigtuple, relid,
						 tupdesc, audit_table);
		rettuple = trigdata->tg_trigtuple;
	}
	else if (TRIGGER_FIRED_BY_UPDATE(trigdata->tg_event))
	{
		insert_audit_row(AUDIT_OP_UPDATE, trigdata->tg_newtuple, relid,
						 tupdesc, audit_table);
		rettuple = trigdata->tg_newtuple;
	}
	else
	{
		elog(ERROR, "pgaudix_trigger: unknown trigger event");
		rettuple = NULL; /* keep compiler quiet */
	}

	SPI_finish();

	return PointerGetDatum(rettuple);
}
