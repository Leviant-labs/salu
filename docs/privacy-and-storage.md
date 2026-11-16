# Data flow and remaining privacy gates

The app stores food snapshots, recipes, batches, weekly meal plans, guided profile
answers, calculated starting estimates, explicit meal feedback, health declarations,
tracking observations and engagement events in its local SQLite database.
These records are included in user-controlled backups and local deletion.
No analytics, crash-reporting or remote-config SDK is included. Optional ChatGPT
plan assistance sends only the payload reviewed for that request; offline planning
and manual recording do not require a provider connection. No image upload queue
is implemented.

The database is not independently encrypted. Protection depends on the device OS,
sandbox, device lock, and its at-rest protection. A compromised/unlocked device can
expose records. Android automatic backup is disabled in the manifest. iOS platform
backup exclusion and file-protection behavior require native implementation and
device verification before release; no iCloud backup promise is made.

User-controlled encrypted exports use AES-256-GCM, random 16-byte salt and 12-byte
nonce, with a 256-bit key derived by PBKDF2-HMAC-SHA256 (210,000 iterations).
The passphrase is never written into SQLite. There is no escrow or recovery.
These are explicit engineering parameters, not an independent security audit.
Exports authenticate their format via associated data. Import checks the format,
KDF parameters, authentication tag, database schema, foreign keys, duplicate keys,
and supported domain-document shapes before replacing live records transactionally.
CSV export is intentionally unencrypted and needs confirmation.

ChatGPT OAuth credentials, the installation host identifier, account registrations
and short-lived pending sign-in state belong exclusively in platform secure storage,
not SQLite or archives. Connecting AI does not create a Salu account. The direct
subscription-access flow follows the [user-selected OpenAI guide](https://developers.openai.com/siwc/token-sharing-open-source).
Each inference requires a live connection, the direct-plan scope and request-specific
transfer consent. Measurements and health declarations are omitted unless separately
selected for sharing. No background or queued-offline prompts are sent.

Conversational text and the model's free-text explanation remain in memory by
default. Reviewed local proposals retain typed changes, local summaries, provider/model
provenance and a hash of the request, not raw prompts or model free text. The
transport requests `store:false`; this is not a promise of no provider-side retention.
Restoring an archive does not restore credentials or transfer consent. A successful
restore disconnects AI; an invalid archive leaves the existing workspace and
connection unchanged.

Delete local data removes catalogue, diary, revision history, documents and command
receipts in a transaction, enables SQLite secure_delete, checkpoints WAL and vacuums.
The app cancels in-flight AI and clears in-memory credentials and its secure-storage
namespace, then reinstalls the bundled catalogue and starter recipes for fresh setup.
It attempts provider revocation separately and reports when remote revocation
could not be confirmed.
SSD wear levelling, OS snapshots,
external backups and exported copies prevent a forensic erasure guarantee.
Native file-picker temporary-copy retention and clearing still need a device audit.
There are currently no app-captured images or thumbnails. Future media capture
must extend deletion to files, temporary/cache copies and cancelled requests.

Deleting local data cannot delete exported files, external health-store records,
or records retained by a provider. Future integrations must expose those separate
operations and their limitations. GDPR legal roles/bases, sensitive-data handling,
transfer terms, archive security and native backup behavior remain release reviews.
