#include "pgaudix.h"

#include "access/htup_details.h"
#include "catalog/pg_type.h"
#include "commands/trigger.h"
#include "executor/spi.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"

PG_MODULE_MAGIC;

/* GUC: whether to capture current_query() in audit rows */
static bool pgaudix_log_query = false;

void _PG_init(void);

PG_FUNCTION_INFO_V1(pgaudix_trigger);

void
_PG_init(void)
{
	DefineCustomBoolVariable(
		"pgaudix.log_query",
		"Log the SQL query text in audit records.",
		NULL,
		&pgaudix_log_query,
		false,
		PGC_SUSET,
		0,
		NULL, NULL, NULL
	);
}

/*
 * Insert one audit row into the audit table.
 *
 * operation: one of "I", "U", "D"
 * tuple: the row data to record
 * tupdesc: tuple descriptor of the source table
 * audit_table: fully qualified audit table name (already quoted)
 */
static void
insert_audit_row(const char *operation, HeapTuple tuple, TupleDesc tupdesc,
				 const char *audit_table)
{
	StringInfoData cols;
	StringInfoData vals;
	int			nparams;
	int			natts = tupdesc->natts;
	int			ncols = 0;
	int			i;
	Datum	   *values;
	Oid		   *types;
	char	   *nulls;
	StringInfoData query;

	/* Count non-dropped columns */
	for (i = 0; i < natts; i++)
	{
		Form_pg_attribute attr = TupleDescAttr(tupdesc, i);
		if (!attr->attisdropped)
			ncols++;
	}

	/*
	 * Parameters: $1 = operation (text)
	 * + ncols data columns from the tuple
	 * Total: 1 + ncols
	 */
	nparams = 1 + ncols;

	values = (Datum *) palloc(nparams * sizeof(Datum));
	types = (Oid *) palloc(nparams * sizeof(Oid));
	nulls = (char *) palloc(nparams * sizeof(char));

	initStringInfo(&cols);
	initStringInfo(&vals);

	/* $1 = audit_operation */
	values[0] = CStringGetTextDatum(operation);
	types[0] = TEXTOID;
	nulls[0] = ' ';

	appendStringInfoString(&cols, "audit_operation");
	appendStringInfoString(&vals, "$1");

	/* Data columns from the tuple */
	{
		int paramidx = 1; /* next parameter index (0-based in arrays, $2 in SQL) */

		for (i = 0; i < natts; i++)
		{
			Form_pg_attribute attr = TupleDescAttr(tupdesc, i);
			bool		isnull;
			Datum		val;

			if (attr->attisdropped)
				continue;

			appendStringInfo(&cols, ", %s", quote_identifier(NameStr(attr->attname)));
			appendStringInfo(&vals, ", $%d", paramidx + 1);

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
			types[paramidx] = attr->atttypid;

			paramidx++;
		}
	}

	/* Build the INSERT query */
	initStringInfo(&query);
	appendStringInfo(&query,
					 "INSERT INTO %s (%s) VALUES (%s)",
					 audit_table, cols.data, vals.data);

	if (SPI_execute_with_args(query.data, nparams, types, values, nulls, false, 0) < 0)
		elog(ERROR, "pgaudix: failed to insert audit row into %s", audit_table);

	pfree(cols.data);
	pfree(vals.data);
	pfree(query.data);
	pfree(values);
	pfree(types);
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

	tupdesc = trigdata->tg_relation->rd_att;

	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "pgaudix: SPI_connect failed");

	if (TRIGGER_FIRED_BY_INSERT(trigdata->tg_event))
	{
		insert_audit_row(AUDIT_OP_INSERT, trigdata->tg_newtuple, tupdesc,
						 audit_table);
		rettuple = trigdata->tg_newtuple;
	}
	else if (TRIGGER_FIRED_BY_DELETE(trigdata->tg_event))
	{
		insert_audit_row(AUDIT_OP_DELETE, trigdata->tg_trigtuple, tupdesc,
						 audit_table);
		rettuple = trigdata->tg_trigtuple;
	}
	else if (TRIGGER_FIRED_BY_UPDATE(trigdata->tg_event))
	{
		insert_audit_row(AUDIT_OP_UPDATE, trigdata->tg_newtuple, tupdesc,
						 audit_table);
		rettuple = trigdata->tg_newtuple;
	}
	else
	{
		elog(ERROR, "pgaudix_trigger: unknown trigger event");
		rettuple = NULL; /* keep compiler quiet */
	}

	if (SPI_finish() != SPI_OK_FINISH)
		elog(ERROR, "pgaudix: SPI_finish failed");

	return PointerGetDatum(rettuple);
}
