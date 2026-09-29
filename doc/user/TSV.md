# Working with TSV files in ComputerUse

ComputerUse provides a small suite for inspecting, reading, querying, editing,
merging, attaching, and translating Scout TSV data. The implementation uses
Scout TSV parsing and serialization rather than defining an independent format.

## Recommended ingest flow

1. Run `tsv_info` on an unfamiliar source to inspect the interpreted key field,
   value fields, type, row/key counts, and possible entity-format fields. Pass
   source interpretation options such as `sep`, `sep2`, `header_hash`, or `type`
   when required. `key_field` and `fields` select an alternative interpretation.
2. Run `tsv_read` with those source options to normalize the source into canonical
   Scout TSV (tab-delimited columns, pipe-delimited multi-values, `#` headers).
   Its text result can be passed to downstream TSV tasks. Callers needing a
   persisted path can request it through the harness option `return_path: true`.
3. Use `tsv_query`, `tsv_edit`, `tsv_merge`, `tsv_attach`, or `tsv_translate` on
   prepared/canonical TSV inputs. These tasks intentionally do not accept
   parser-only delimiter and header options. If a source needs reinterpretation,
   normalize it again with `tsv_read` first.

## Tasks at a glance

| Need | Task | Result |
|---|---|---|
| Inspect table shape | `tsv_info` | JSON summary; optional metadata rewrite |
| Normalize or subset a source | `tsv_read` | Scout TSV text; harness can return persisted result path |
| Fetch exact key values | `tsv_query` | JSON query records in request order |
| Replace a cell or row | `tsv_edit` | Updated source and TSV text; harness can return persisted result path |
| Merge tables | `tsv_merge` | TSV text; harness can return persisted result path |
| Attach fields | `tsv_attach` | TSV text; harness can return persisted result path |
| Translate identifiers | `tsv_translate` | TSV text; harness can return persisted result path |

## Scout TSV data shape

| Type | Typical row value | Interpretation |
|---|---|---|
| `single` | `"42"` | One scalar per key |
| `list` | `["42", "yes"]` | One scalar per value field |
| `flat` | `["a", "b"]` | Flattened values without stable named-field boundaries |
| `double` | `[["a"], ["b"]]` | An array of values per value field |

A typical header is `#ID\tGene\tScore`; `ID` is the key field and remaining
columns are value fields. `#: :type=:double` is a type annotation. `sep` is the
column separator (tab by default), `sep2` the multi-value separator (pipe by
default), and `header_hash` the header/comment marker (`#` by default).

## `tsv_info`

`tsv_info` returns the selected key field and value fields, type, materialized
row/key counts, and candidate fields matching registered `Entity.formats`.
Candidate names are hints, not validated entity identifiers. `type`, `key_field`,
`fields`, delimiters, and header marker describe how to interpret the source.

The optional `new_key_field`, `rename_fields`, `cast`, `new_type`, `namespace`,
and `identifiers` parameters request an atomic source rewrite. The summary
reflects the updated metadata. `cast` accepts `to_i` or `to_f`; `new_type` accepts
`single`, `list`, `flat`, or `double`. `type` is only a parse override; use
`new_type` to persist a type conversion. For `cast`, `namespace`, and
`identifiers`, nil or empty inputs mean no update, not a clear operation. The
identifier path is metadata only; it does not translate values.

## `tsv_read`

`tsv_read` is the parser-facing normalization operation. It accepts an allowlisted
set of Scout TSV opening controls (`type`, `sep`, `sep2`, `key_field`, `fields`,
`cast`, `select`, `grep`, `persist`, `header_hash`, `field`, `identifiers`,
`namespace`, `merge`, and `one2one`) plus exact `keys` selection and optional
output field/key renaming. It does not forward arbitrary options.

Text output is canonical Scout TSV: tab-separated columns, pipe-separated
multi-values, and `#` headers, independent of source parsing delimiters and
header markers. `identifiers` associates mapping metadata; it does not perform
translation. `persist` controls parser/cache persistence, not output location.
`keys` retains exact key names. A caller that needs a path instead of the text
can set the harness-level `return_path: true` option; the task does not declare
that option or create a task-specific output file.

```ruby
prepared = ComputerUse.job(:tsv_read, nil,
  file: 'genes.csv', sep: ',', header_hash: '', type: 'double').run
```

## Downstream tasks

`tsv_query` fetches exact keys in request order and reports `{key, found, value}`
for each, including misses. A `column` selects `key` or one named value field;
without it, the full row is returned. `cast` accepts `to_i` and `to_f` and is
applied recursively. Named columns are unsupported for `flat` TSVs.

`tsv_edit` takes `file`, `key`, and either `field` plus scalar `value` or a full
`row` encoded as JSON. Successful edits rewrite the input source atomically. JSON
row shapes are scalar for `single`, one scalar per field for `list`, an array of
scalars for `flat`, and an array of per-field scalar arrays for `double`. Values
are serialized as TSV strings. Invalid JSON, absent keys/fields, and invalid
shapes fail before source replacement. Named field edits on `flat` are rejected.
A successful result is normalized TSV text; the caller can request the persisted
job result path using the harness-level `return_path: true` option. That option
does not select or replace the mutated source.

`tsv_merge` requires matching key field, fields, type, and non-filename
annotation metadata. `replace` (default) keeps left-only rows and replaces a
whole colliding row with the right row. `zip` is distinct and supported only for
`double` TSVs. Neither source is modified.

`tsv_attach` explicitly names `match_key` and `other_key` (key or value field),
attaches selected right-side fields to matching source rows, ignores right-only
rows, and leaves unmatched source rows. It rejects `flat` inputs, duplicate
right-side matching values, and field collisions. Scout's attach operation
mutates its receiver, so ComputerUse works on a copy. No identifier translation
is implicit.

`tsv_translate` explicitly invokes `TSV.translate` for `field`, `target_format`,
and an identifier mapping file. It returns a new table and does not mutate the
source. Setting `identifiers` in `tsv_info` or `tsv_read` is metadata assignment,
not value translation.

## Mutation safety and outputs

`tsv_edit` always mutates its source on success. `tsv_info` mutates only when a
metadata mutation input is provided. Mutation requires a writable regular,
non-symlink input and writable parent directory; replacement uses a
same-directory temporary file and rename. Read/query/merge/attach/translate do
not modify their sources. TSV-producing tasks return text by default. A
caller can set the harness-level `return_path: true` option to retrieve the
persisted job result path; this is not an input declared by TSV tasks.
`tsv_info` and `tsv_query` return JSON.

There is no `tsv_write` task. Consult WorkflowCoder `task_inputs` for the exact
live task input schema before calling a task.
