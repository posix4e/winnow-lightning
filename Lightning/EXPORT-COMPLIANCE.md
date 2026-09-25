# Encryption declaration and initial beta distribution

Reviewed September 25, 2026 for this regtest application and PQLN revision
`1d7dda453dd385f3ede84c39eed5d20afe34e02a`. This records the technical basis for
Apple's documentation questions. It is not a government classification ruling
or a claim of FIPS module certification.

## Implementation facts

The application uses encryption, including third-party implementations outside
Apple's operating system. Its algorithms are publicly specified: ML-KEM-768
(FIPS 203, `fips203` 0.4.3), ML-DSA-44 (FIPS 204, `fips204` 0.4.6),
ChaCha20-Poly1305, secp256k1, SHA-256/SHA-3 and HKDF/HMAC. Bitcoin signatures
remain ordinary Bitcoin signatures. Apple Keychain and file protection protect
local app access and storage.

The PQ fork combines these algorithms in a custom hybrid Lightning handshake
and onion protocol. Those integrations are published in its public source;
they do not introduce a proprietary encryption algorithm. Winnow's claim
extension authenticates canonical terms using SHA-256 and the pinned ML-DSA
invoice signature. A private wire format is not itself an encryption algorithm.

Sources: [pinned KEM implementation](https://github.com/ahmet-kurt/pq-rust-lightning/blob/1d7dda453dd385f3ede84c39eed5d20afe34e02a/lightning/src/crypto/pq_kem.rs),
[hybrid peer transport](https://github.com/ahmet-kurt/pq-rust-lightning/blob/1d7dda453dd385f3ede84c39eed5d20afe34e02a/lightning/src/ln/peer_channel_encryptor.rs),
[FIPS 203](https://csrc.nist.gov/pubs/fips/203/final),
[FIPS 204](https://csrc.nist.gov/pubs/fips/204/final).

## Apple's documentation determination

For the initial scope, the factual answers are:

| Question | Answer |
| --- | --- |
| Uses encryption | Yes |
| Implements third-party standard cryptography | Yes |
| Implements proprietary encryption algorithms | No |
| Intended for the French App Store | No |

Apple's [documentation table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/)
requires the French declaration for standard algorithms outside the operating
system only when distributing on the French App Store. On September 25, Apple's
API rejected creation of a documentation record for the answers above with
`ENTITY_ERROR.ATTRIBUTE.INVALID`: a record requires proprietary cryptography,
or third-party cryptography together with French Store availability. No record
was created and no government approval was obtained by this request.

Consequently this release sets `ITSAppUsesNonExemptEncryption=NO`, meaning
exempt from Apple's documentation requirement for this scope, **not** that it
uses no encryption or that all legal obligations are waived. Apple documents
this distinction in [Complying with Encryption Export Regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).
No export-compliance code is invented or copied from another app. The release
manifest records the answers and the SHA-256 of this assessment.

## Distribution controls and changes of scope

The owner selected an initial rollout excluding mainland China and France.
This release goes only to the existing internal TestFlight group, with no public
link or App Store submission. App Store territory settings are not treated as
a geographic control for TestFlight. The release operator must confirm where
every current group member will test before assigning the build.

Supply a private JSON object mapping tester IDs to their confirmed two-letter
country codes using `scripts/lightning-testflight distribute --build NUMBER
--tester-countries /absolute/path/tester-countries.json`. Every member must be
present; extra/missing IDs and `CN`/`FR` are rejected. Never infer a country from
an email address, citizenship, account name, IP address or this Mac's timezone.
Keep this file outside the repository. The What to Test notes tell testers not
to use or redistribute this beta in the excluded destinations. These controls
are operator-managed, not GPS enforcement.

Before adding a destination or changing cryptographic functionality, reassess
the declaration and applicable export/import requirements. French App Store
distribution needs a new determination and any required French filing. Mainland
China distribution needs its own app-distribution review. Any separate U.S.
classification, notification or reporting obligation must be evaluated under
the applicable rules; Apple's upload acceptance is not a government ruling.
