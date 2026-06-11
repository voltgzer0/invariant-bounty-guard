# Security

The Invariant Bounty Guard primitive is built to be a security tool. We treat reports against this repository the same way we expect protocols to treat reports against the deployed implementation: fast, paid, and quiet until disclosure is coordinated.

## Reporting a vulnerability

Please **do not** open a public GitHub issue.

Contact directly:

- **Email**: voltmattty77@gmail.com (PGP key on request)
- **Telegram**: @voltgzer0

Include:

1. A description of the vulnerability and the attack path.
2. A proof-of-concept against the published interface in this repository, or against a deployed instance you have permission to test.
3. Your preferred bounty payout address.

## Acknowledgement

We respond to verified reports within 72 hours. Coordinated disclosure timeline is agreed per report.

## Scope

In scope:
- Cryptographic / economic flaws in the design documented in `README.md` or `src/IInvariantGuard.sol`.
- API-level issues that misrepresent the guarantees of the primitive.

Out of scope:
- Issues only reproducible by reverse-engineering or re-implementing the unpublished implementation.
- Social engineering, phishing, or non-technical attacks against the author.
