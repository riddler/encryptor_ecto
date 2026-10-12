### Fixed

- A table name with a trailing newline, such as `"wrapped_keys\n"`, is now refused at configuration like any other name that is not an unquoted lowercase identifier: `Encryptor.Ecto.KeyStore` and `Encryptor.Ecto.SuspensionStore` answer `{:error, {:invalid_config, :table, :invalid_name}}`, and the `--table` option of the migration generators exits with their usual "unquoted table name" refusal. The grammar previously let one trailing newline through.
