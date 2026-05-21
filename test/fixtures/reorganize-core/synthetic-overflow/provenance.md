# Reorganize Synthetic Overflow Provenance

This synthetic variant uses the same logical reorganize inputs as the
baseline fixture, but deliberately records oversized execution units so
the runner must report the existing `DiagnosticChecksFailed` path.
