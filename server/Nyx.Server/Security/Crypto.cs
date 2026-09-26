using System.Security.Cryptography;
using System.Text;

namespace Nyx.Server.Security;

/// <summary>Server-held secret material (signs tokens, protects TOTP secrets, derives decoy salts).</summary>
public sealed class ServerKeys(byte[] master)
{
    public byte[] Master { get; } = master;

    public byte[] Derive(string purpose, int length = 32) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, Master, length, info: Encoding.UTF8.GetBytes(purpose));

    public static ServerKeys LoadOrCreate(string path)
    {
        if (!File.Exists(path)) File.WriteAllBytes(path, RandomNumberGenerator.GetBytes(64));
        return new ServerKeys(File.ReadAllBytes(path));
    }
}

public static class Sealed
{
    /// <summary>AES-256-GCM: base64(nonce | tag | ciphertext).</summary>
    public static string Protect(byte[] key, string plain)
    {
        var data = Encoding.UTF8.GetBytes(plain);
        var nonce = RandomNumberGenerator.GetBytes(12);
        var tag = new byte[16];
        var ct = new byte[data.Length];
        using var aes = new AesGcm(key, 16);
        aes.Encrypt(nonce, data, ct, tag);
        return Convert.ToBase64String([.. nonce, .. tag, .. ct]);
    }

    public static string Unprotect(byte[] key, string blob)
    {
        var all = Convert.FromBase64String(blob);
        var ct = all[28..];
        var pt = new byte[ct.Length];
        using var aes = new AesGcm(key, 16);
        aes.Decrypt(all[..12], ct, all[12..28], pt);
        return Encoding.UTF8.GetString(pt);
    }
}

public static class Hashing
{
    public static string Sha256(string s) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(s)));

    public static string RandomToken(int bytes = 32) =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static bool ConstantTimeEquals(string a, string b) =>
        CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(a), Encoding.UTF8.GetBytes(b));
}

/// <summary>RFC 6238 time-based one-time passwords (Google Authenticator compatible).</summary>
public static class Totp
{
    const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    public static string NewSecret() => Base32(RandomNumberGenerator.GetBytes(20));

    public static string Uri(string secret, string account, string issuer = "Nyx") =>
        $"otpauth://totp/{System.Uri.EscapeDataString(issuer)}:{System.Uri.EscapeDataString(account)}" +
        $"?secret={secret}&issuer={System.Uri.EscapeDataString(issuer)}&digits=6&period=30";

    /// <summary>Accepts the current step +-1. Returns the accepted step (to block replay) or null.</summary>
    public static long? Verify(string secret, string code, long lastUsedStep = 0)
    {
        if (code.Length != 6 || !code.All(char.IsDigit)) return null;
        var key = FromBase32(secret);
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / 30;
        for (var step = now - 1; step <= now + 1; step++)
        {
            if (step <= lastUsedStep) continue;
            if (Hashing.ConstantTimeEquals(Code(key, step), code)) return step;
        }
        return null;
    }

    /// <summary>The code an authenticator app would show at the given moment (used by tests and diagnostics).</summary>
    public static string Generate(string secret, DateTimeOffset? at = null) =>
        Code(FromBase32(secret), (at ?? DateTimeOffset.UtcNow).ToUnixTimeSeconds() / 30);

    static string Code(byte[] key, long step)
    {
        var msg = BitConverter.GetBytes(step);
        if (BitConverter.IsLittleEndian) Array.Reverse(msg);
        var h = HMACSHA1.HashData(key, msg);
        var o = h[^1] & 0xF;
        var bin = ((h[o] & 0x7F) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
        return (bin % 1_000_000).ToString("D6");
    }

    static string Base32(byte[] data)
    {
        var sb = new StringBuilder();
        int buffer = 0, bits = 0;
        foreach (var b in data)
        {
            buffer = (buffer << 8) | b;
            bits += 8;
            while (bits >= 5) { sb.Append(Alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5; }
        }
        if (bits > 0) sb.Append(Alphabet[(buffer << (5 - bits)) & 31]);
        return sb.ToString();
    }

    static byte[] FromBase32(string s)
    {
        var bytes = new List<byte>();
        int buffer = 0, bits = 0;
        foreach (var c in s.ToUpperInvariant())
        {
            var v = Alphabet.IndexOf(c);
            if (v < 0) continue;
            buffer = (buffer << 5) | v;
            bits += 5;
            if (bits >= 8) { bytes.Add((byte)(buffer >> (bits - 8))); bits -= 8; }
        }
        return [.. bytes];
    }
}
