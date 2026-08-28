### Added

- `Encryptor.Ecto.String` declares an encrypted text field: everything
  `Encryptor.Ecto.Binary` does, with a cast arm that accepts only valid UTF-8,
  so bytes from a mis-decoded payload become an error on the field instead of a
  column that decrypts years later into something no reader can render.
- `Encryptor.Ecto.Map` declares an encrypted map field, serialized through
  `:json` - any module exporting `encode!/1` and `decode!/1`, `Jason` by
  default - and checked at the declaration rather than on the first write.
- A loaded map has string keys - guaranteed by the default serializer, and
  trusted of a host-supplied one - and `%{}` round-trips as `%{}` rather than
  collapsing into `nil`.
- A struct handed to a map field is refused at `cast/2` rather than silently
  round-tripping into a plain map.
- A serializer failure raises `Encryptor.Ecto.SerializationError` naming the
  serializer and the direction, with the serializer's own exception reduced to
  its module: `Jason`'s carries the value it could not encode, and this package
  does not pass that on.
