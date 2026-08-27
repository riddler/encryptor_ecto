defmodule Encryptor.Ecto do
  @moduledoc """
  Encrypted Ecto types for the [Encryptor](https://github.com/riddler/encryptor)
  vault - `cloak_ecto`-shaped field encryption for Ecto schemas.

  Encryptor answers where key material comes from and which key a given
  record's data belongs to. What it does not do is put that behind a schema
  field, and hand-rolling the glue is where field encryption usually goes
  wrong: the ciphertext ends up in a column nobody remembers to widen, the
  cast/load/dump arms disagree about `nil`, and the tenant a value belongs to
  is resolved differently at every call site.

  This package is that glue, in the shape Ecto already expects. Encrypted
  fields are `Ecto.Type` modules a schema declares like any other type, so the
  changeset, the query, and the migration all keep their ordinary form, and
  the column changes to `:binary` and nothing else.

  Nothing is implemented yet. This module exists so the package has a root;
  the type surface, the tenant-context strategy, and the error vocabulary are
  each being decided in an ADR before any of them is built.
  """
end
