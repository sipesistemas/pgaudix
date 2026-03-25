# pgaudix — Usage

## Install

```sql
CREATE EXTENSION pgaudix;
```

## Enable auditing

```sql
SELECT pgaudix.enable('my_table');
```

## Disable auditing

```sql
-- Keep audit data
SELECT pgaudix.disable('my_table');

-- Delete audit data
SELECT pgaudix.disable('my_table', drop_data := true);
```

## Check monitored tables

```sql
SELECT * FROM pgaudix.status();
```

## Query audit data

```sql
SELECT * FROM my_table_audit ORDER BY audit_id;
```

### Filter by operation

```sql
-- Only inserts
SELECT * FROM my_table_audit WHERE audit_operation = 'I';

-- Only updates
SELECT * FROM my_table_audit WHERE audit_operation = 'U';

-- Only deletes
SELECT * FROM my_table_audit WHERE audit_operation = 'D';
```

### Filter by time

```sql
SELECT * FROM my_table_audit
WHERE audit_timestamp >= now() - interval '1 hour';
```

### Filter by user

```sql
SELECT * FROM my_table_audit
WHERE audit_user = 'app_service';
```

## Operations reference

| `audit_operation` | Meaning | Row contains |
|-------------------|---------|--------------|
| `I`               | INSERT  | New values   |
| `U`               | UPDATE  | New values   |
| `D`               | DELETE  | Old values   |

> The "before" values of any UPDATE are the previous audit row for that record.
