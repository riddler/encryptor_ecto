### Fixed

- The `mix encryptor.ecto.migrate` failure line prints a host reason that is an improper list, such as `[:a | "x"]`, instead of crashing; `Encryptor.Ecto.Error.redact/1` renders the tail after a bar. The reduction applied to a host reason keeps a list's length, so a charlist payload shows as many `:redacted` elements as it has characters, as `redact/1` shows a binary's byte count.
