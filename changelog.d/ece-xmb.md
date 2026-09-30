### **Breaking**

- **Breaking.** A migration plan field whose `from:` is one of this package's
  own types declared with `legacy:` - a reverse plan run while the migration
  window is open - no longer compiles without `source_authenticated:`, because
  a row the vault cannot read is read through that legacy module. Declare
  `source_authenticated:` on each such field with the answer the forward plan
  gave for the same legacy cipher: `true` for an authenticated cipher such as
  AES-GCM, `false` (with a `validate:`) otherwise.
