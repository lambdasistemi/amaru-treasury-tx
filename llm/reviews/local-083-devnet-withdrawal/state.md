state: ReadyForExternalReview
mode: solo
role: all
branch: 083-devnet-withdrawal
issue: 83
base_ref: main
predecessor_pr: 93
predecessor_state: merged
upstream_cardano_node_clients_main: d6773e4cd8a2421617568c8dac0972b0f312a509
feature_dir: specs/083-devnet-withdrawal
updated_by: codex
notes: "Acceptance strengthened before merge: withdraw DevNet smoke now signs/submits the built withdrawal and proves materialized ADA. Latest live evidence is runs/devnet/20260515T091231Z with submitted tx ff78a866216fbe1b3cb2bf356f3a01cc088ab13260d50fd0b7b4b019b4a3b52d, materialized output #0 carrying 2000000 lovelace, reward 2000000 -> 0, and treasury ADA 200000000 -> 202000000. Final gate passed after report-accounting schema/golden refresh."
