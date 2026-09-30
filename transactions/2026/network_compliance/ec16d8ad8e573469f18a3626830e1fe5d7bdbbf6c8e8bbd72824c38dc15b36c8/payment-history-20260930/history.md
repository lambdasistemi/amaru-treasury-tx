# Cyber Castellum payment history and month convention

Checked 2026-09-30T15:12:41.930064+00:00; source: freshly fetched main commit `1c61ca757fd935d2f5a80f2a85ceded8f7440979`. Archived submitted transaction body IDs and descriptions were decoded and matched to each intent. This is archive history, not a fresh complete on-chain duplicate-payment search.

All payments are 18,750 USDM to the established CAG payee.

| Invoice | Billing period | Review/description month | Paid | Archived transaction |
| --- | --- | --- | --- | --- |
| #3508 | April 2026 | May 2026 | 2026-05-22 | [c150d5c5](c150d5c5c67658c8f2a3bc24e16a4852257d46a03224257ac990fcca6f6fde78/summary.md) |
| #3516 | May 2026 | June 2026 | 2026-07-13 | [968fd01e](968fd01e074ca33de95087957f59803bb2ee8bacfe922eb81cdf18e8e23ad788/summary.md) |
| #3522 | June 2026 | July 2026 | 2026-07-13 | [0abab118](0abab118fb103b983b177fb80c247803f3b5ff7f5d98202ddd2f071b017cb23d/summary.md) |
| #3528 | July 2026 | August 2026 | 2026-08-27 | [4f64f292](4f64f292d2b8d74f9bade3bdcafb92302b79b6589208147c995e55057b7696b4/summary.md) |
| #3536 | August 2026 | September review and description | Not submitted | Current signed candidate |

The four submitted payments and the corrected current candidate label the review/acceptance cycle, one month after the work billed. Submission dates need not equal review months: June and July cycles both submitted July 13.

The September manifest and build script default to September 2026. The superseded candidate explicitly overrode the description to August to name the invoice billing period. The corrected current candidate uses the default September description; its invoice and amount remain unchanged.

The operator skill requires the cycle manifest as the source of reference evidence and an invoice/amount cross-check. No explicit mandatory description-month rule was found; the script permits an override.

The September wording has been restored through a fresh wizard/build, and both new signatures have been verified and assembled. The old signed candidate remains preserved as superseded evidence. No submission was performed.

Primary invoice #3508 was freshly downloaded from its archived CID and confirms April billing. #3516 and #3522 billing periods are recorded in submitted summaries; #3528 and #3536 original PDFs were rechecked locally.
