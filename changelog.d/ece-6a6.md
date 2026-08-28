### Changed

- **`:bits` is applied.** A blind index declared `bits: 64`, `128` or `192`
  now stores that many bits - the leading 8, 16 or 24 bytes of the
  `HMAC-SHA256` - instead of the full 32 bytes it stored while ADR-0003
  decision 6's option half was carried unapplied. `bits: 256` remains the
  default and is unchanged. This is a behaviour change for any declaration
  already carrying a narrower width; no host has stored a blind index value
  yet, so nothing needs reindexing.
- `Encryptor.Ecto.BlindIndex.Value.byte_width/1` reports a declaration's
  stored width in bytes, which is what a host sizes its index column against.

### Notes

- **The output is truncated, never the key.** The index key stays the full 32
  bytes the derivation produces, and `:bits` never reaches the HKDF `info`
  string - so a width change stores different bytes under the *same* key. A
  shortened HMAC key would be a weakened HMAC; decision 6 asks for a collision
  knob on the stored value, and collisions are a property of the value's
  width.
- **The leading bytes are kept.** RFC 2104 section 5 defines HMAC truncation
  as "the leftmost t bits" and NIST SP 800-107 section 5.3.1 says the same for
  any approved hash output. Either end is equally sound here, so this is a
  convention rather than a security choice - but it is a constant a host's
  stored bytes depend on forever, so it is written down at
  `Encryptor.Ecto.BlindIndex.Value` rather than left to the reader of a
  `binary_part/3`.
- **Truncation happens in one place**, inside the single function every
  surface computes through, so `put_index/3` and `where_eq_candidates/3`
  cannot store and pin different widths. That is ADR-0003 decision 5's promise
  applied to decision 6, and it is why `:bits` is read at no call site.
- A `:bits` change invalidates the column exactly as a normalizer change does
  (decision 7): the stored value changes even though the key does not, so the
  two-column dance is the migration.
- **`:slow` is still carried rather than applied.** ADR-0003 decision 6 puts
  Argon2id's parameters in "the vault's configuration rather than this
  package's", and the vault exposes no Argon2id surface to read them from.
  Choosing a parameter set here would be this package making a cryptographic
  decision inline, which this repository's conventions call a defect even when
  the choice is a good one. A declaration written with `slow: true` is
  accepted, checked and carried, and does nothing.
