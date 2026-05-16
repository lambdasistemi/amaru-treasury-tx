# Tasks review

decision: Changes requested after command-gap review

Findings:

- The original tasks completed the production-backed smoke path but did
  not include the shipped `amaru-treasury-tx` command required by the
  parent #151 command-recovery story.
- T033-T044 reopen #147 with a blocking command slice and make the
  subagent brief explicit: exact owned files, forbidden scope, RED
  parser/runner proof, GREEN build/devnet proof.
- The PR must not return to external review until T035-T044 are
  implemented, reviewed, verified locally, documented, and reflected in
  PR metadata.
