### Added

- A migration plan field may name `index: :some_index_column` to fold a blind
  index into the rewrite pass: the pass computes the index from the plaintext
  it already loaded, through the same declaration `put_index/3` uses, and
  writes it in the same compare-and-swap update as the ciphertext. Without the
  option the pass writes ciphertext only, as before, and the index remains a
  separate backfill. A failure computing the index is reported against the row
  as `{:blind_index, column, reason}`.
