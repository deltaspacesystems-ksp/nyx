# Nyx architecture (v2)

Private Discord-like app for a handful of people. English UI. The server never sees message
content, attachments, names, avatars or banners in plaintext.

## Layout
- `server/Nyx.Server` - ASP.NET Core 10: REST + SignalR + EF Core/SQLite. Runs on the E: server behind nginx.
- `client/` - Flutter (Windows, Linux, iOS, Android, web).
- `tools/turn` - Go relay (pion/turn) for voice/screen share when peers cannot connect directly.
- `deploy/` - nginx include, management scripts.

## Model
- **Guild** (a "server"): owner, roles with permission bits, categories/channels, invites, custom emoji.
- **Channel**: text / voice / category in a guild, or DM (2 people) / group DM (2-10) with no guild.
- **Membership = access.** A user is a channel member if there is a `ChannelMember` row; they can decrypt
  if they hold a `KeyShare` for the key version. Removing someone rotates the key (new version, sealed to
  the remaining members) so they cannot read anything new.
- Roles/permissions are metadata, enforced by the server (who may send, invite, kick, manage). Reading is
  enforced by cryptography (key possession).

## Cryptography (client side only)
- Identity: Ed25519 (signatures) + X25519 (key agreement), generated on device. Password -> Argon2id ->
  auth key (sent) + wrapping key (never sent, encrypts the private-key backup).
- Guild key, channel key: random 256-bit, AES-256-GCM, sealed per member to their X25519 key (per version).
- Guild/channel names, topics, role names, icons, banners: `MetaCipher` encrypted with the guild/channel key.
- Profile (bio, status text, avatar, banner, accent, theme): `ProfileCipher` encrypted with a per-user
  profile key, sealed to every other user.
- Messages: signed (Ed25519) then encrypted; replies/edits/reactions carry only ciphertext + opaque tags.
- Files (attachments, avatars, banners, emoji): chunked AES-GCM with a per-file key that lives inside the
  encrypted message/profile/meta. Server stores opaque blobs with an access scope (channel/guild/profile).
- Calls: WebRTC P2P (DTLS-SRTP); signalling is signed+encrypted with the channel key.

## Security
- Access token 15 min (JWT with session id) + rotating refresh token; reuse of an old refresh token
  revokes the whole session. Sessions are listable/revocable, revocation drops live connections.
- Argon2id client-side + server PBKDF2 of the auth key; lockout with backoff; optional TOTP 2FA with
  recovery codes; password change re-wraps the key backup and revokes other sessions.
- Rate limits per IP/user on every group of endpoints; message flood limit; storage quotas; size limits.
- Every endpoint checks membership/permission; blobs are only served to members of their scope.
- Audit log of security events. Strict headers. TURN: short-lived HMAC credentials, per-user allocation
  quota, no relaying to private networks.
