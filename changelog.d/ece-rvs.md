### Added

- `Encryptor.Ecto.Declarations.check_unique!/1` refuses a deploy in which two
  encrypted fields share one declared table and column - fields that can
  silently decrypt each other's bytes - and `list/1` reports what a deploy
  considers encrypted and under what context.
- The `:table` and `:column` pins may be written at the field as well as at
  the `use`, so renaming a physical table or column is a one-line change that
  leaves every stored row readable.
