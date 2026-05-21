# Reorganize Synthetic Golden Provenance

This fixture is synthetic. It exercises the direct reorganize runner
offline with a frozen `ChainContext`.

The fixture starts with two treasury UTxOs and expects the builder to
produce one continuing treasury output that preserves their combined
value exactly. `expected.cbor` is generated only after the RED phase.
