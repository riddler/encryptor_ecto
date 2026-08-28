# ADR-0003: keyed blind indexes, per-tenant by default, equality only

Status: accepted (2026-08-27, with one amendment: index keys are derived
subkeys of the tenant master key for now - enc-ADR-0003 decision 7's
`"encryptor/v1/blind-index"` label - so the search-only capability claim is
softened to a key-hierarchy claim; independently wrapped index keys are the
recorded upgrade path if a search-only consumer materializes. See the A9
resolution below.)

## Proposed amendments (2026-08-27)

Status: **proposed**. Acceptance is the operator's; until then the decision
text below is unchanged and these two sections are the operative reading of
the points they name. They resolve `ece-0rn` items 1 and 2 - two places
where this record contradicts itself rather than two new decisions.

The operator's ruling of 2026-08-27, verbatim:

> accept all recs as written, D1) rule that :version participates, and amend
> d2's info string to include it; D2) compose by nesting - the index key is
> derived as a subkey under the upstream label, and d2's literal prefix
> becomes the info string inside that subkey derivation

**1. `:version` participates in the derivation, and decision 2's `info`
string carries it (D1).** Decision 7 says an index carries a `:version` that
participates in the HKDF `info` (decision 2); decision 2's `info` string
carries a prefix, a table, a column and an `index_name`, and no version
component. Decision 7 is the operative half - "rule that `:version`
participates" - and decision 2's `info` string is amended to include it:

```
info = "encryptor_ecto/blind_index/v1|" <> table <> "|" <> column <> "|" <>
       index_name <> "|" <> Integer.to_string(version)
```

`:version` is already in `index_opts/0` as `version: pos_integer()` and
defaults to `1`, so an index that declares no version derives under
`...|<index_name>|1` and nothing about an existing declaration changes.

What the amendment buys is the property decision 7 assumes and decision 2
did not deliver: **a version bump derives different key bytes**. Without it
the new column in the two-column rotation dance would be recomputed to
byte-identical values, and the sequence would rotate nothing while reporting
that it had. The version joins `index_name` for the same reason `index_name`
is there - it distinguishes two indexes over one column - and it is what
makes a key rotation, as opposed to a second concurrent index, expressible.

**2. The upstream label and decision 2's prefix compose by nesting (D2).**
The acceptance amendment above derives index keys as subkeys under
enc-ADR-0003 decision 7's `"encryptor/v1/blind-index"` label. Decision 2
states its own literal domain-separation prefix. Neither supersedes the
other - the acceptance amendment's "What survives in full" list keeps "index
keys are never encryption keys (domain separation, decision 2)" - and the
unwritten part was how the two labels compose. They "compose by nesting -
the index key is derived as a subkey under the upstream label, and d2's
literal prefix becomes the info string inside that subkey derivation":

```
index_root = HKDF-Expand(
  tenant_master_key,
  info = "encryptor/v1/blind-index",
  32
)

index_key = HKDF-SHA256(
  ikm  = index_root,
  salt = <vault-configured, per-deployment>,
  info = "encryptor_ecto/blind_index/v1|" <> table <> "|" <> column <> "|" <>
         index_name <> "|" <> Integer.to_string(version)
)
```

Two derivations, in order, each separating at its own layer. The outer label
separates the whole blind-index tree from every other use of a tenant master
key, and belongs to enc-ADR-0003 decision 7, which reserves the
`"encryptor/v<n>/<purpose>"` namespace for exactly this. The inner prefix
separates this package's index derivation from anything else that might one
day derive under that tree, and belongs to this record. Both halves of the
structural "never the encryption key" guarantee therefore hold, and the
`ikm` line of decision 2 reads as the *derived index root* for that scope
rather than the scope's key material directly.

The capability claim is unaffected: computing `index_root` requires the
tenant master key, so this remains the key-hierarchy claim the acceptance
amendment softened it to, not a search-only capability.

## Proposed amendment (2026-08-28): the salt is real, and it is an extract

Status: **proposed**. Acceptance is the operator's. This section is additive
and changes no decision above; it records where the shipped construction's
*expression* differs from the 2026-08-27 pseudocode, and why the difference is
an implementation of that pseudocode rather than a departure from it.

Decision 2 and the D2 amendment both write `salt = <vault-configured,
per-deployment>`, and assumption A10 asks the vault for one. At the time both
were written the vault had no salt to give: `Encryptor.Kdf` was HKDF-*Expand*
only, deliberately and on the record, and HKDF-Expand has no salt parameter.
So `ece-d72` first shipped the nesting with the salt unexpressed and the gap
flagged. The operator settled it on 2026-08-28:

> I agree with the salt ruling - add the salt now via an upstream HKDF-Extract
> amendment, shaped to A8's {ikm_selector, salt, info, length}

`encryptor`'s ADR-0003 amendment A (proposed, 2026-08-28) is that upstream
amendment. It adds `Encryptor.Kdf.extract/2`, the composed
`salted_subkey/5`, a per-deployment `:derivation_salt` in vault
configuration, and `Encryptor.Vault.derive/3` shaped to A8 exactly. A8, A10
and A11 are therefore discharged, and this record's `ikm` line no longer has
to be read as "whatever the caller happens to hold".

**1. The salt sits at the extract of the key material, not as a second HKDF's
salt.** The D2 amendment's pseudocode places the salt on the inner derivation,
over `index_root`. The shipped construction places it one step earlier, at the
extract of the tenant master key, and then performs both expansions unsalted:

```
PRK         = HKDF-Extract(salt: vault's :derivation_salt, ikm: key material)
purpose_key = HKDF-Expand(PRK, "encryptor/v1/blind-index", 32)
index_key   = HKDF-Expand(purpose_key, "encryptor_ecto/blind_index/v1|" <>
                table <> "|" <> column <> "|" <> index_name <> "|" <>
                Integer.to_string(version), 32)
```

Both readings are the same nesting with the same two domain separations in the
same order, and both make every derived byte a function of the salt. The
difference is which of the two HKDF halves the salt is spent on, and that is
`encryptor`'s call rather than this record's: the key-derivation scheme is the
vault's under this project's cross-repo seam, and amendment A decision 4 fixes
the construction in full. Placing it at the extract is also the RFC's own
shape - a salt is an extract input, and section 3.1 describes it as
strengthening the extract step - so the shipped form is HKDF used as specified
rather than a salt threaded into an expand that has no parameter for one.

Nothing a host observes changes between the two readings except the bytes,
and no bytes exist yet: no host has stored a blind index value, and amendment
A's consequences section makes the same argument on its own side. This is the
one moment the choice is free.

**2. The derivation asks the vault and never receives key material.** Decision
2's `ikm` line, and the D2 amendment's restatement of it, both name key
material as an input to a derivation this package performs. It no longer is
one. `Encryptor.Ecto.BlindIndex.Derivation` names a purpose, a selector, an
`info` and a length; `Encryptor.Vault.derive/3` resolves the descriptor,
derives inside its own call, and returns derived bytes. There is no argument
on any function in this package that a tenant master key can be passed as.

That is a strengthening of A8 and A11 rather than a change to any decision:
decision 2 says what the derivation *is*, and this says who performs it. The
capability position is unchanged - a component holding a vault that can derive
an index key is a component that can also decrypt, which is what the A9
resolution above already softened the search-only claim to.

**3. A missing salt is a refusal, not a default.** A vault with no
`:derivation_salt` configured answers `{:missing_config, [:derivation_salt]}`
and derives nothing. This package passes that through unchanged rather than
re-phrasing it, because it is a fact about a deployment's vault configuration
and not about an index declaration.

**4. Rotating `:derivation_salt` is a reindex.** The salt is effectively
permanent from the first stored index value, exactly as a key rotation and a
normalizer change are (decision 7, and the "every invalidating change is a
reindex" consequence). `encryptor`'s amendment A flags the same thing for its
runbook. It is recorded here because the operator who rotates the salt is
reading this record's rotation section, not that one.

## Context

ADR-0001 closed the door on querying encrypted columns and left one door open
behind it. Its decision 10 says, in as many words, that there is no
`searchable` option and there will not be one, and that exact-match lookup is
this record's job. So this record has a narrow, well-specified brief: **make
`where email == "..."` work against a column whose ciphertext is
non-deterministic, without weakening anything ADR-0001 decided.**

The technique is not new. A blind index stores, in a second column beside the
encrypted one, a deterministic fingerprint of the plaintext. Equality on
plaintext becomes equality on fingerprint. The whole design question is what
the fingerprint is computed with, and everything that goes wrong with blind
indexes in the wild goes wrong there.

**The ecosystem has no answer, and the pattern in circulation is weak.** There
is no maintained Elixir blind-index package. What hosts do instead - visible in
blog posts, in Stack Overflow answers, in more than one production schema - is
`:crypto.hash(:sha256, String.downcase(value))` into a `:binary` column. That
is not a blind index; it is a public fingerprint that happens to live in a
private database. An attacker holding a dump and no keys at all can recover
every value in that column whose plaintext comes from a guessable space, and
the columns hosts most want to search on - email address, phone number, tax
identifier, postal code, last name - are exactly the guessable spaces. A
national identifier with a known check-digit structure is a few billion
candidates, which is minutes. Making the fingerprint *keyed* is the entire
security value of the feature, and it is the part the folk pattern omits.

**Cloak had `cloak_ecto`'s blind-index story; it was thin.** The ecosystem
precedent that exists is Paragon's `CipherSweet` (PHP) and its port attempts:
keyed hashes, per-field keys, planned index widths, and a strong statement
about what the index leaks. That prior art is good and this record follows most
of it. Where it diverges is tenancy, because ADR-0001 already made a tenancy
decision this package is bound by.

**ADR-0001 constrains the design in three specific ways**, and none of them are
negotiable here:

- *Tenant context is explicit process scope, and its absence raises*
  (decision 5a, 5c). Whatever computes an index value needs the same tenant,
  from the same place, with the same fail-closed behaviour. An index helper
  that silently succeeded where an encrypt would have raised would be a hole
  drilled through the one decision ADR-0001 called its hard decision.
- *Table and column are derived, never supplied* (decision 4). The index's key
  derivation has the same information available and should use it the same way,
  for the same reason: a host cannot forget what it never supplies.
- *Per-field key derivation was explicitly deferred* (ADR-0001's closing
  Consequences: distinct keys per column are "out of scope here", on the
  grounds that the column already rides the AAD). That reasoning holds for
  *encryption* keys and does not transfer to index keys, because an index value
  has no AAD - it is a bare fingerprint in a column, with nothing binding it to
  its position. This record therefore introduces per-field derivation for index
  keys only, and open question Q1 records the tension.

**The failure that motivates the key hierarchy.** An index key and an
encryption key must never be the same bytes. The index value is, by
construction, a value an attacker can compute if they hold the key - that is
what makes it searchable. If the searching key and the decrypting key are the
same key, then any component that legitimately needs to *build a query* (a
search service, an admin console, a data pipeline) must hold the key that
*decrypts every row*. Separating them at derivation time means a compromise
of an index key discloses the equality structure of one field rather than
the contents of the database - and, if the derivation surface ever supports
it, that the search capability could be handed out without the decrypt
capability. (As accepted, it does not yet: see the A9 resolution below.)

**The motivating host is a multi-tenant host app** with a small number of
exact-match lookups (find the record by email, find it by phone) over columns
that are otherwise encrypted at rest, and a hard requirement that deleting a
tenant's key material renders that tenant's data unrecoverable. That last
requirement bears directly on the per-tenant question below: an index derived
from a global key survives tenant key deletion, and a "crypto-shredded" tenant
whose blind indexes still answer equality questions about its data has not been
shredded in any sense a compliance conversation will accept.

## Decision

**1. The index value is a keyed HMAC, not a hash.** For a field's declared
normalization `norm`, the stored value is:

```
index_value = HMAC-SHA256(index_key, norm(plaintext))
```

stored whole - 32 bytes - in a `:binary` column. Unkeyed hashing is not offered
under any option name. Truncation is available per field (decision 6) but is
not the default, because the default should be the safe one and truncation
trades a real security property for a leakage property most hosts do not want.

**2. Index keys are derived, per field, from the encryptor HKDF primitive, and
are never the encryption key.** The derivation is:

```
index_key = HKDF-SHA256(
  ikm  = <key material for this scope: tenant key, or the global index root>,
  salt = <vault-configured, per-deployment>,
  info = "encryptor_ecto/blind_index/v1|" <> table <> "|" <> column <> "|" <> index_name
)
```

Three properties of that `info` string are load-bearing. The literal prefix
domain-separates index derivation from every other use of the same key
material, so an index key can never collide with an encryption key derived from
the same input - that is the "never the encryption key" guarantee, and it is
structural rather than a matter of configuration discipline. The table and
column come from `Ecto.ParameterizedType` params exactly as in ADR-0001
decision 4, so a host cannot forget them or misspell them. And `index_name`
distinguishes two indexes over the same column (decision 6: a full index and a
truncated one, or a rotation pair).

The consequence hosts feel: **two columns holding the same plaintext produce
different index values**, so an attacker cannot join `users.email` against
`contacts.email` in a dump, and cannot detect that a value appearing in one is
the same value appearing in the other.

**3. Derivation is per tenant by default, and the global choice is loud.** This
is the record's hard decision and it is argued against ADR-0001's tenant model
directly.

**3a.** The default for a field whose type module is declared `tenant: :scope`
(ADR-0001's default) is `scope: :tenant`: the HKDF input keying material is the
tenant's key material, resolved through the same `Encryptor.Ecto.TenantContext`
resolution ADR-0001 decision 5f defines. The index helper does not have its own
tenant channel and does not read the process dictionary itself; it asks the
field's configured tenant strategy, so a host that replaced `:scope` with a
resolver module gets the same replacement here for free.

**3b.** Per-tenant is the default for two reasons that follow from ADR-0001
rather than from taste.

*Cross-tenant non-correlatability.* A global index key makes the index value a
function of the plaintext alone. Two tenants storing the same email address
produce identical bytes in the index column, and anyone holding the database -
including a tenant with legitimate access to their own rows through an
application bug, and including anyone holding a backup - can see that tenant A
and tenant B share a customer. That is a disclosure across the exact boundary
ADR-0001 spent its whole decision 5 defending. Per-tenant derivation makes the
same plaintext produce unrelated bytes in different tenants.

*The index shreds with the key.* ADR-0001 decision 5e already names crypto-
shreddability as the property a `tenant: :none` field gives up, which
establishes that this package treats shreddability as a property worth
tracking at the field. A per-tenant index key inherits it: destroy the tenant's
key material and the index column becomes 32 bytes of noise that answers no
question, because nobody can compute a candidate index value to compare against
it any more. A global index key does not inherit it, and leaves behind a column
that still answers "does this tenant have a record with email X" for any X an
attacker cares to guess, forever.

**3c.** `scope: :global` exists and must be written at the field. It is the
correct choice for a genuinely shared reference table - the same case ADR-0001
decision 5e carves out with `tenant: :none` - and for the one case per-tenant
derivation cannot serve at all: **a lookup that must find a row without knowing
which tenant it belongs to.** Login by email address across a shared identity
table is the canonical example, and it is a real requirement, not a
hypothetical. Per-tenant derivation cannot answer it, because computing the
candidate index value requires already knowing the tenant.

The API forces that choice out loud. A field declared on a `tenant: :scope`
type with no `:scope` option gets per-tenant derivation. Declaring
`scope: :global` on such a field is accepted and its consequences are in the
option's documentation and in the security-properties table below. Declaring
nothing on a `tenant: :none` type is **a compile-time error**, not a silent
fallback to global: a global field's index has to say `scope: :global` even
though it is the only possibility, because the reviewer reading that schema
line is the person who needs to know that this column is cross-tenant
correlatable. Silence is exactly what a reviewer does not see.

**3d.** A field may declare both: a per-tenant index for in-tenant lookups and
a separate `scope: :global` index for the cross-tenant path, under different
`index_name`s and therefore different keys and different columns. That is the
supported answer to "I need both", and it makes the cross-tenant leakage
attach to one named column rather than to the whole field.

**4. Normalization is declared per field, applied before the HMAC, and is part
of the index's identity.** An index answers equality over `norm(plaintext)`,
never over plaintext, and the host declares which `norm`:

| Normalizer | Does |
|---|---|
| `:none` | Byte-exact (default) |
| `:trim` | `String.trim/1` |
| `:downcase` | `String.trim/1` then `String.downcase/1` |
| `:email` | `:downcase` (the local part is case-sensitive per RFC, and no host wants that) |
| `:digits` | Keep `[0-9]` only - phone numbers, tax identifiers, postal codes |
| `{module, function}` | Host-supplied `(String.t() -> String.t())` |

Normalizers are pure, total, and must not raise on any binary; a host
normalizer that raises produces `Encryptor.Ecto.BlindIndex.NormalizationError`
naming the table and column and no value.

Two consequences are stated rather than discovered. Normalization is
**lossy and directional**: the index finds `"Bob@Example.COM "` when asked for
`"bob@example.com"`, and a host that treats an index hit as proof of byte
equality is wrong. And changing a field's normalizer **invalidates the column** -
every existing row's index value was computed under the old rule - so a
normalizer change is a reindex, handled exactly like a key rotation
(decision 7). The normalizer is deliberately *not* mixed into the HKDF `info`,
because doing so would turn a normalizer change into a silent no-match instead
of a change the host has to plan; the reindex is the honest path.

**5. Two helpers, and no magic.** The index column is an ordinary column the
host declares in its migration and its schema. This package does not write
migrations, does not add fields to schemas, and does not hook `Repo`
callbacks.

*Write side* - a changeset helper computes the column:

```elixir
changeset
|> cast(attrs, [:email])
|> Encryptor.Ecto.BlindIndex.put_index(:email, :email_index)
```

`put_index/3` reads the cast plaintext, applies the field's normalizer,
computes the HMAC, and puts the result. If the source field was not changed,
the index is not recomputed. If the source field is being set to `nil`, the
index is set to `nil` (decision 8).

*Read side* - a query helper rewrites the equality:

```elixir
from(u in User) |> Encryptor.Ecto.BlindIndex.where_eq(:email, "bob@example.com")
```

which expands to `where: u.email_index == ^computed`. Only equality, and only
against a literal or pinned value; there is no `where_like`, no `where_gt`, no
ordering helper, and no dynamic operator argument that could be made to
generate one.

Both helpers resolve the field's index configuration from the schema module, so
the declaration lives in exactly one place and the two helpers cannot disagree
about normalization or key derivation. **Both raise on missing tenant scope,
identically to ADR-0001 decision 5c** - including `where_eq/3`, which means a
query *built* outside tenant scope raises at build time rather than returning
no rows. A blind-index query that silently matches nothing is the single worst
failure this feature can have, because it looks exactly like "the record does
not exist".

**6. Index width and slow hashing are per-field options, both defaulting to the
safe end.**

| Option | Default | Meaning |
|---|---|---|
| `:name` | the column name | The `index_name` in the HKDF `info` (decision 2) |
| `:scope` | `:tenant` | `:tenant` or `:global` (decision 3) |
| `:normalize` | `:none` | Decision 4 |
| `:bits` | `256` | Stored width; `64`/`128`/`192` truncate the HMAC |
| `:slow` | `false` | `true` runs Argon2id before the HMAC (below) |

*Truncation* (`:bits`) is a deliberate collision knob, not a storage
optimization. A narrower index produces false-positive matches at a known rate,
which blurs the equality structure an attacker reads out of the column - at the
cost that **the host must filter the candidate rows after decrypting them**.
Truncation is therefore only correct where the caller expects a set, and
`where_eq/3` on a truncated index returns a *candidate* set by contract; the
documentation says so at the option and the helper is named
`where_eq_candidates/3` for truncated indexes so the call site cannot forget.
This is CipherSweet's planned-index-width idea and the credit belongs there.

*Slow hashing* (`:slow`) addresses the one thing HMAC does not: an attacker who
obtains the index key can still enumerate a low-entropy space offline.
Argon2id over the normalized value, before the HMAC, makes each guess cost
what a password hash costs. It is off by default because it costs the same on
every write and every query, and it is worth turning on for exactly the fields
whose plaintext space is small and high-value. Parameters come from the vault's
configuration rather than this package's, and **changing them invalidates the
column** the same way a normalizer change does.

**7. Index columns are versioned, and rotation is a two-column dance.** An
index key cannot be rotated in place: every stored value would have to be
recomputed from plaintext, which requires decrypting every row. So rotation is
a migration, and this record makes it a supported one rather than an
improvisation. A field may declare more than one index, and an index carries a
`:version` that participates in the HKDF `info` (decision 2). The sequence is:

1. Add the new column and declare the new index version alongside the old.
2. `put_index/3` writes both (declaring both means both are written).
3. Backfill the new column over the existing rows, batched, in tenant scope.
4. Switch `where_eq/3` to the new version.
5. Drop the old column and its declaration.

Nothing here is automatic and nothing is inferred from a config change. The
same sequence covers a normalizer change, a `:bits` change, and an Argon2id
parameter change, which is why they are all called invalidating rather than
each getting its own mechanism.

**8. `nil` indexes as `NULL`, and empty indexes as empty.** Exactly ADR-0001
decision 7's rule, for the same reason: presence is already visible, and a
`NULL` plaintext with a non-`NULL` index would leak that a value exists. A
`""` plaintext produces a real index value over `norm("")`, which is a
constant per key - a host indexing a column where empty string is common is
publishing that fact to anyone reading cardinality, and the documentation says
so.

**9. Equality only. This is the whole surface, permanently.** No `LIKE`, no
prefix search, no range, no ordering, no `MIN`/`MAX`, no `BETWEEN`, no sort.
This package will not implement order-revealing encryption, searchable
symmetric encryption, or an n-gram/substring index, and will not accept a
contribution that does. Those schemes have leakage profiles that require a
threat-model analysis per deployment, and a library that ships them as an
option ships that analysis undone. A host that genuinely needs substring search
over sensitive data needs a different architecture (a separately-secured search
service with its own boundary), not an option flag here.

Unique constraints *are* supported, on the index column, with the caveat that
uniqueness is then uniqueness of `norm(plaintext)` per key scope - which for a
`:tenant`-scoped index means per-tenant uniqueness and for `:global` means
global. That is usually what the host wanted, and it is worth naming because it
is the one place the scope choice changes application semantics rather than
only leakage.

## Security properties

What an attacker learns from a database dump, with no key material, from a
column indexed under this record. "Equality structure" means: which rows share
a value, and how many distinct values exist.

| Attacker holds | Learns from a `:tenant`-scoped index | Learns from a `:global` index |
|---|---|---|
| The dump only | Equality structure within each tenant; nothing across tenants | Equality structure across the entire table and across every table sharing that index name |
| The dump, and knows a specific plaintext is present somewhere | Nothing - cannot compute a candidate without the key | Nothing - same |
| The dump + one tenant's index key | Which rows in *that tenant* hold any plaintext they can guess; nothing about other tenants | Which rows anywhere hold any plaintext they can guess |
| The dump + an index key, low-entropy field, `slow: false` | Full plaintext recovery over the guessable space for that scope | Same, across all tenants |
| The dump + an index key, `slow: true` | Recovery at Argon2id cost per guess | Same |
| The dump + an index key + the encryption key | Everything; the index adds nothing at that point | Same |
| A destroyed tenant key, dump retained | Nothing; the column is unusable noise | **Equality structure survives the shred**, and guessable values remain recoverable to an index-key holder |

Three rows deserve to be read twice. The second row is the actual security
claim of this record and the thing the unkeyed folk pattern does not have: with
no key, a known plaintext cannot be confirmed present. The fourth row is why
`:slow` exists. The last row is the crypto-shredding argument of decision 3b
stated as an attacker capability, and it is the reason `:global` has to be
written out loud.

Two things this record does not defend against, stated so nobody assumes
otherwise. **Frequency analysis within a scope**: an index over a field with a
skewed distribution (a country code, a status-like string that someone
mistakenly indexed) tells an attacker which value is most common, and the
plaintext is usually guessable from that alone - which is why the guidance is
to reserve indexes for high-cardinality exact-match keys. And **an attacker who
can inject rows and observe the index column** learns the index value of a
plaintext of their choosing, which is a chosen-plaintext oracle over the index
key's scope; that is inherent to any deterministic index and is bounded by the
scope, which is one more argument for per-tenant.

## Upstream API assumptions

Extending ADR-0001's table; A1-A7 there are unchanged and this record does not
restate them. These are equally review items for acceptance.

| # | Assumed | Used by |
|---|---|---|
| A8 | The vault exposes an HKDF-SHA256 derivation primitive taking `{ikm_selector, salt, info, length}` and returning derived key bytes, without exporting the input key material itself | 2 |
| A9 | Derived index key bytes can be obtained for a tenant *without* obtaining that tenant's encryption key, so that a search-only capability is expressible | 2, and the security-properties table |
| A10 | The vault carries a per-deployment salt (or a stable equivalent) usable as the HKDF salt, distinct from any encryption salt | 2 |
| A11 | Key material is addressable by the same opaque tenant identifier A7 assumes, and asking for a derived key does not create or cache one implicitly | 3a |
| A12 | Argon2id parameters live in vault configuration and are readable by this layer as an opaque parameter set | 6 |
| A13 | Derived key material is held in a form that does not appear in `Inspect` output, logs, or exception messages, matching ADR-0001 decision 6's prohibition | 2, 5 |

If A9 is wrong - if index-key derivation requires the encryption key in hand -
decision 2 still holds and the *capability separation* claim in the security
table weakens to a key-hierarchy claim only. That is the one assumption whose
failure changes what this record promises rather than only how it is built,
and it is flagged for acceptance accordingly.

*Resolved at acceptance (2026-08-27): A9 is wrong as stated, and the record
is accepted with the weakened claim. enc-ADR-0003 decision 7's derived
subkeys require the tenant master key in hand, so a component that can
compute index values can also decrypt; the security table's "search without
decrypt" reading does not hold today. What survives in full: index keys are
never encryption keys (domain separation, decision 2), the index shreds
with the tenant key, and every leakage row of the security table. The
genuine search-only capability requires an independently random,
independently wrapped index key per tenant - a second `WrappedKey` row and
provisioning step - which enc-ADR-0003 open question 4 holds open as the
recorded upgrade path. A8 and A10-A13 are design obligations on the
derivation surface, to be honored when it is built.*

## The contract as typespecs

```elixir
defmodule Encryptor.Ecto.BlindIndex do
  @type scope :: :tenant | :global

  @type normalizer ::
          :none
          | :trim
          | :downcase
          | :email
          | :digits
          | {module(), atom()}

  @type index_opts :: [
          name: atom(),
          scope: scope(),
          normalize: normalizer(),
          bits: 64 | 128 | 192 | 256,
          slow: boolean(),
          version: pos_integer()
        ]

  @doc "Declares an index on a source field. Used inside a schema module."
  @spec blind_index(source :: atom(), column :: atom(), index_opts()) :: Macro.t()

  @doc "Computes and puts the index column for a changed source field."
  @spec put_index(Ecto.Changeset.t(), source :: atom(), column :: atom()) ::
          Ecto.Changeset.t()

  @doc "Adds an equality constraint on a full-width index."
  @spec where_eq(Ecto.Queryable.t(), source :: atom(), term()) :: Ecto.Query.t()

  @doc """
  Adds an equality constraint on a truncated index. Returns candidates:
  the caller filters after decrypting.
  """
  @spec where_eq_candidates(Ecto.Queryable.t(), source :: atom(), term()) ::
          Ecto.Query.t()

  @doc "The index value itself, for hosts building their own queries."
  @spec compute(schema :: module(), source :: atom(), term()) :: binary()
end
```

`compute/3`, `put_index/3`, `where_eq/3`, and `where_eq_candidates/3` have no
`:error` arm, on purpose and for ADR-0001 decision 6's reason: the failure
paths raise.

| Condition | Exception |
|---|---|
| No tenant in scope, `scope: :tenant` | `Encryptor.Ecto.MissingTenantError` (ADR-0001's) |
| Key derivation fails upstream | `Encryptor.Ecto.BlindIndex.DerivationError` |
| A host normalizer raises or returns a non-binary | `Encryptor.Ecto.BlindIndex.NormalizationError` |
| `where_eq/3` used against a truncated index | `ArgumentError`, at compile time where the schema is known |
| Index declared on a field this package does not encrypt | `ArgumentError`, at compile time |

No exception message, log line, or `Inspect` output ever carries plaintext, an
index value, or key material. ADR-0001 decision 6 made that prohibition part of
the decision rather than a review preference, and it extends here unchanged -
with index values added to the list, because an index value is a directly
usable search token for anyone who logs it.

## Worked example

A multi-tenant host app, continuing ADR-0001's `customers` table, that needs to
find a customer by email within the current tenant and by phone within the
current tenant, and to look up an account by email across tenants at login.

```elixir
# Migration - ordinary columns, declared by the host.
alter table(:customers) do
  add :email,       :binary
  add :email_index, :binary
  add :phone,       :binary
  add :phone_index, :binary
end

create unique_index(:customers, [:tenant_id, :email_index])
create index(:customers, [:phone_index])
```

```elixir
defmodule MyApp.Accounts.Customer do
  use Ecto.Schema
  import Encryptor.Ecto.BlindIndex

  schema "customers" do
    field :tenant_id, :binary_id

    field :email, MyApp.Encrypted.String
    field :email_index, :binary
    blind_index :email, :email_index, normalize: :email

    field :phone, MyApp.Encrypted.String
    field :phone_index, :binary
    blind_index :phone, :phone_index, normalize: :digits, slow: true
  end
end
```

```elixir
def changeset(customer, attrs) do
  customer
  |> cast(attrs, [:email, :phone])
  |> validate_required([:email])
  |> put_index(:email, :email_index)
  |> put_index(:phone, :phone_index)
  |> unique_constraint([:tenant_id, :email_index])
end

# In request scope for tenant "acct_A":
from(c in Customer) |> where_eq(:email, "Bob@Example.com ") |> Repo.one()
# -> the customer, found through normalize -> HMAC under acct_A's index key.

# The identical call in tenant "acct_B"'s scope finds nothing, even if
# acct_B has a customer with that address: different key, different bytes.

# Outside any scope, the query does not silently return nothing:
# ** (Encryptor.Ecto.MissingTenantError) customers.email_index: no tenant in
#    scope; call Encryptor.Ecto.Tenant.put/1 or wrap/2 at this boundary
```

The cross-tenant login path is a *different* index, declared out loud on the
shared identity table:

```elixir
defmodule MyApp.Accounts.Identity do
  use Ecto.Schema
  import Encryptor.Ecto.BlindIndex

  schema "identities" do
    # tenant: :none per ADR-0001 decision 5e - a genuinely global field.
    field :email, MyApp.Encrypted.GlobalString
    field :email_index, :binary
    blind_index :email, :email_index, scope: :global, normalize: :email
  end
end
```

`scope: :global` is mandatory on that declaration even though it is the only
legal value for a `tenant: :none` field (decision 3c). The reviewer looking at
that line learns, without reading this ADR, that `identities.email_index` is a
column whose equality structure spans every tenant and survives a tenant shred.

## Open questions

These are tensions with ADR-0001 that this record deliberately does not resolve
on its own authority. ADR-0001 is a sibling record and is not amended here.

**Q1. Per-field derivation, deferred there, introduced here.** ADR-0001's
closing Consequences defer per-field key derivation, reasoning that the column
already rides the AAD. Decision 2 here introduces per-field derivation for
index keys, because an index value has no AAD to ride. The two positions are
compatible as stated - different key hierarchies for different jobs - but a
reviewer should confirm that reading rather than infer it, and confirm that the
`encryptor` key hierarchy actually has room for a second derivation tree.

**Q2. Whether index-key derivation should be scoped to a capability, not just a
key.** A9 assumes a search-only capability is expressible. If the vault has no
notion of a capability - if holding derivation access implies holding key
access - then the "hand out search without decrypt" property is aspirational
and the security table's fourth row should be softened before acceptance. This
is a question for the `encryptor` records, not for this one.

**Q3. Where `where_eq/3` should get its tenant when the query is built in one
process and executed in another.** ADR-0001 decision 5b says process scope does
not propagate and hosts wrap explicitly. A query is data and can outlive its
building process. This record binds at *build* time (decision 5), which is the
fail-loud choice, but it means a query struct carries a tenant-specific
constant that is invisible in the struct and wrong if the struct is reused
across scopes. Whether that warrants a guard - stamping the query and checking
at execute - is unresolved.

**Q4. Whether a `tenant: :none` field should be able to declare a
`:tenant`-scoped index at all.** Decision 3c makes it a compile error, on the
grounds that a global ciphertext with a per-tenant index is an incoherent pair.
There may be a legitimate case (a shared table where reads are always
tenant-qualified anyway) that this forecloses. Left as an error until somebody
brings the case.

**Q5. The `:digits` normalizer and international phone numbers.** Stripping to
digits is right for a single-country host and loses the distinction between
`+1 555 0100` and `5550100` in a way that could merge two real people's rows,
which matters because decision 9 supports unique constraints over the index.
Whether the founding set should ship a phone normalizer at all, or leave it to
`{module, function}` with a documented warning, is a judgement this record
makes one way (ship it) and flags.

## Consequences

**Exact-match lookup exists, and nothing else does.** ADR-0001's decision 10
promised this record would cover exact match and nothing would cover ranges;
decision 9 here honours the second half as firmly as the first. Schema design
upstream of this package still has to assume encrypted columns are opaque.

**Per-tenant by default costs a real capability.** Cross-tenant lookup requires
a deliberate second index on a deliberately global field. Hosts whose mental
model is "one users table, find by email" will meet that cost at design time -
which is the intent, because meeting it at design time is how the cross-tenant
correlation gets to be a decision rather than an accident.

**Every invalidating change is a reindex.** Normalizer, width, Argon2id
parameters, and key rotation all require the decision 7 sequence, and a reindex
requires decrypting every row in tenant scope. Hosts should expect to choose a
field's normalization once, and the documentation should say so where the
option is declared rather than in a rotation appendix nobody reads first.

**The helpers are explicit, and can therefore be forgotten.** `put_index/3` is
a line in a changeset, so a second write path that does not call it produces a
row whose index is stale or absent, and whose lookup silently misses. This is
the mirror image of ADR-0001's central property: encryption cannot be forgotten
because it lives in the type, while indexing can be, because it lives in the
call site. Making the index automatic would mean a `Repo` hook or a changeset
macro that owns `cast/3`, which is a much larger intrusion into the host than
this package should make - so the mitigation is documentation, a compile-time
warning where a declared index has no `put_index/3` call reachable in the
schema's own changeset functions if that proves detectable, and a test-support
assertion the host can run over its own write paths. Naming the gap is better
than hiding it.

**Adding a blind index is a schema decision with a leakage cost, per column.**
The security-properties table is the deliverable a host reviews before adding
one, not after. A column that gets an index publishes its equality structure
inside the index's scope, permanently, to anyone who ever holds a backup - and
that is true even when everything in this record is implemented correctly.
