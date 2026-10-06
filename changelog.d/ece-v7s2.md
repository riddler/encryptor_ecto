### **Breaking**

- The key store's lookup column is `scope_ref`, with its unique index over
  `(scope_ref, version)`: `mix encryptor.ecto.gen.key_store_migration` writes
  that column and every key-store query reads it. A wrapped-key table
  generated before 0.8.0 (column `tenant_ref`) is not read by this version,
  and no migration renames the column: such a table also holds v1 rows
  (ADR-0006 Amendment A, A3), so a host that has one stays on 0.7.x or
  re-encrypts every row, which neither package ships. A host that has not
  created the table yet runs the generator as before.
