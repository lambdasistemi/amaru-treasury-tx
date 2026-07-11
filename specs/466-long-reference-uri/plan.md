# Plan: long rationale reference URIs

1. Add a RED unit test for the exact Pinata HTTPS URI, chunk caps, and round-trip.
2. Reuse the existing UTF-8-safe 64-byte chunking primitive in `splitUri`, retaining the
   canonical short `ipfs://` shape.
3. Run focused tests, explicit revert/restore, and `./gate.sh`.
4. Pin the candidate upstream connection-loss commit and build the Linux AppImage.
5. Run the exact unsigned transaction build five times; do not sign or submit.
