# plan — #33

One bisect-safe slice (S1), OWNER topology.

1. Replace the two partial helpers in `IntentJSON.Common` with one
   total helper (F-1) deriving the expected length from the hash
   algorithm.
2. Migrate every `lib/` call site to thread the `Left` through the
   parser it sits in (REQ-2); delete the duplicates in
   `DisburseIntentJSON` and import the shared helper (REQ-3).
3. Make the devnet constant helper total (REQ-4).
4. Unit tests: properties INV-1/INV-2 over the helper; parser-level
   wrong-length examples INV-3 through public parser entries.
5. Goldens/schemas untouched (INV-5).

Live boundary: none (pure parsing). Gate: `just ci` plus CI jobs.
