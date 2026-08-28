### Added

- `Encryptor.Ecto.BlindIndex.put_index/3` computes a declared index column
  from the cast plaintext: it applies the field's normalizer, derives the
  index key through the vault, and puts the HMAC. A source field that was not
  changed is not recomputed, and a source set to `nil` sets the index to `nil`
  - a `NULL` plaintext beside a non-`NULL` index would leak that a value
  exists (ADR-0003 decision 8).
- `Encryptor.Ecto.BlindIndex.where_eq/3` adds an equality constraint on the
  index column, against a computed value. Equality is the whole surface
  permanently (ADR-0003 decision 9): there is no `where_like`, no `where_gt`,
  no ordering helper, and no operator argument that could be made to generate
  one.
- `Encryptor.Ecto.BlindIndex.where_eq_candidates/3` is the same constraint
  under the weaker contract a truncated index answers under. `where_eq/3`
  refuses a truncated index by name, so a call site that has to filter the
  rows after decrypting them cannot forget that it does.
- `Encryptor.Ecto.BlindIndex.compute/3` returns the index value itself, for a
  host building its own query. It is a directly usable search token, and is on
  the never-logged list beside plaintext and key material.
- Each of the three read helpers has a four-argument form naming the index
  column, for a field carrying more than one index - ADR-0003 decision 7's
  rotation window, where both versions are declared and the source field names
  neither, and decision 3d's per-tenant and `scope: :global` pair. The
  three-argument form refuses an ambiguous field rather than choosing a key
  for the caller.

### Notes

- **Both sides raise on a missing tenant, `where_eq/3` included.** A query
  *built* outside tenant scope raises where it is built rather than executing
  and matching nothing, which is the failure ADR-0003 decision 5 calls the
  worst this feature can have, because it looks exactly like "the record does
  not exist".
- A write-side computation asks the field's tenant strategy with `:dump` and a
  read-side computation asks with `:load`, matching what the encrypted field
  itself would be doing at the same moment.
- `:bits` and `:slow` are still carried rather than applied: a declaration
  written with `bits: 64` stores a full-width value until decision 6's option
  half lands. `where_eq/3`'s refusal reads the declared width and nothing
  computes with it.
- A tenant *key* rotation is not ADR-0003 decision 7's rotation. Only the
  current encryption key is consulted upstream, so rotating a tenant's key
  changes every index key under it without any declaration changing, and
  values stored under the superseded key stop being derivable - `where_eq/3`
  then matches nothing and raises nothing. The record does not describe that
  case and this package invents no behaviour for it: a host rotating a tenant
  key must reindex that tenant's index columns.
