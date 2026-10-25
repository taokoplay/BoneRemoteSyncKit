OneDrive Personal synthetic HTTP fixture

server.py uses only the Python standard library and binds to 127.0.0.1 on an ephemeral port. OneDriveTestServer creates a separate temporary workspace per test and provides internal-only Graph/token/download endpoint overrides. No real Microsoft account, cloud file, registered application or credential is used.

The fixture checks synthetic Authorization/form/path values and provides protocol, refresh, pagination, cancellation and file-integrity failure cases. The 1 MiB payload is the concatenation of SHA256(i) for i=0..<32768, encoded as its UTF-8 decimal string. It is used for byte-for-byte download checks, not a public-network performance claim.

The HTTP fixture runs only in macOS tests. Production targets do not depend on Python or expose the endpoint overrides.
