# Data flow and remaining privacy gates

This development build stores food snapshots, recipes, batches, plans, preferences,
tracking observations and engagement events in the app's SQLite database. No
analytics, crash-reporting or remote-config SDK is included. No provider or health
transport is connected; no image upload queue is implemented.

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

Provider secrets belong exclusively in platform secure storage. The dependency
is installed; no current provider connection accepts or persists keys. Future
provider implementations must pass the authorization/distribution/consent gates
before connecting. Restored archives never restore provider authorization.

Delete local data removes catalogue, diary, revision history, documents and command
receipts in a transaction, uses SQLite secure_delete, checkpoints WAL and vacuums.
The app also clears its secure-storage namespace. SSD wear levelling, OS snapshots,
external backups and exported copies prevent a forensic erasure guarantee.
Native file-picker temporary-copy retention and clearing still need a device audit.
There are currently no app-captured images or thumbnails. Future media capture
must extend deletion to files, temporary/cache copies and cancelled requests.

Deleting local data cannot delete exported files, external health-store records,
or records retained by a provider. Future integrations must expose those separate
operations and their limitations. GDPR legal roles/bases, sensitive-data handling,
transfer terms, archive security and native backup behavior remain release reviews.
