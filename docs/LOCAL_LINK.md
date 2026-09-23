# Direct local link protocol (version 1)

Material Capture on iPhone sends .pbrcapture data directly to Material Lab on Mac. The service name is _materiallab._tcp, with Bonjour TXT keys version=1 and instance=<Mac pairing UUID>. Files/AirDrop carries the same .pbrcapture schema when the link is unavailable.

The Mac owns a self-signed P-256 TLS identity. Its certificate leaf is SHA-256 hashed in DER form. The Mac displays a QR object containing version=1, service=_materiallab._tcp, leafSHA256 (lowercase hexadecimal), a 256-bit base64url one-time token, and expiresAt in UTC ISO 8601. The iPhone verifies the leaf hash in the TLS verification callback before sending any capture bytes. The trusted fingerprint is stored in iPhone Keychain and can be revoked; rotating the Mac identity invalidates the old pin. Bonjour discovery does not establish trust by itself.

After TLS, the iPhone sends a four-byte unsigned big-endian length followed by one UTF-8 .pbrcapture JSON payload. The length must be between 1 and 64 MiB inclusive. For this path the JSON includes link.token matching the unexpired QR. The Mac checks token, format, source and optional map hashes, dimensions, privacy fields, and duplicate capture ID, then asks the Mac user to approve the capture. Approval atomically saves it to the camera inbox. The Mac returns one similarly framed acknowledgement: either {ok:true,captureId:<UUID>} or {ok:false,error:<short reason>}, then closes. Approval or rejection consumes the token.

An interrupted transfer must leave no completed inbox entry. A malformed, oversized, unpaired, expired, or rejected payload must produce no import. The QR token is an authorization for a proposed transfer, not a substitute for certificate pinning or Mac approval. There is no plaintext transfer mode.
