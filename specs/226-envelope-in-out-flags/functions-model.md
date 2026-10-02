# functions model — #226

- F1 `runEnvelope :: EnvelopeKind -> EnvelopeIO -> IO ()` (REQ-1..3).
- F2 `runDeEnvelope :: EnvelopeIO -> IO ()` (REQ-1..4).
- F3 an `EnvelopeIO` option parser shared by the four commands (REQ-1, REQ-5).
