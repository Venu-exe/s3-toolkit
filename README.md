# S3 Toolkit

![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white) ![AWS S3](https://img.shields.io/badge/AWS%20S3-232F3E?style=for-the-badge&logo=amazons3&logoColor=white) ![status](https://img.shields.io/badge/status-active-brightgreen?style=for-the-badge) ![license](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)

Bash tools for working with S3 buckets — enumerate bucket names for recon, then optionally inspect what a publicly-reachable bucket actually exposes.

---

### ⚠️ Scope & Ethics

Only run `s3-hunter.sh` against domains/keywords **you own or are explicitly authorized to test** (e.g. in-scope for a bug bounty program). Unauthorized scanning of third-party infrastructure may violate acceptable-use policies or the law.

**Ethical Hacking Only** · **Responsible Disclosure** · **No Harm. Just Protection.**

---

### What's new in v3.0

- **`--inspect`** — for every bucket found to be publicly reachable, the tool now goes one step further (read-only, no writes, no object downloads):
  - Lists up to `--max-keys` top-level object keys, if anonymous `ListBucket` is allowed.
  - Checks whether the bucket ACL or bucket policy document is itself anonymously readable, and flags dangerous grants (e.g. `WRITE` or `FULL_CONTROL` open to `AllUsers`).
- **`-o report.json`** — machine-readable JSON report of every bucket found (public or private), including any exposure notes, so results can feed into other tooling or a bug bounty write-up.
- Still zero AWS credentials required — every check is an unauthenticated HTTP request, same as v1/v2.

---

### Arsenal

| Tool | What it does | Needs AWS account? |
|---|---|---|
| `s3-hunter.sh` | lazys3-style enumeration — generates bucket-name permutations for a keyword, checks each in parallel, and (with `--inspect`) probes public buckets for listable objects and ACL/policy exposure | ❌ No |
| `common-bucket-words.txt` | 170-word list of common bucket-naming patterns for `s3-hunter.sh -w` | — |

---

### Usage

**s3-hunter.sh** — bucket name recon

```
./s3-hunter.sh <keyword> [-w wordlist.txt] [-t threads] [--inspect] [--max-keys N] [-o report.json]
```

```
./s3-hunter.sh mycompany
./s3-hunter.sh mycompany -w common-bucket-words.txt -t 20
./s3-hunter.sh mycompany --inspect
./s3-hunter.sh mycompany --inspect --max-keys 50 -o report.json
```

Flags:

| Flag | Description | Default |
|---|---|---|
| `<keyword>` | Base word to permute (company name, domain, etc.) — required | — |
| `-w <file>` | Custom wordlist of prefixes/suffixes (one per line) | built-in 170-word list |
| `-t <n>` | Parallel threads | `10` |
| `--inspect` | Probe public buckets: list top-level object keys, check ACL/policy exposure | off |
| `--max-keys <n>` | Max object keys to list per bucket (only with `--inspect`) | `20` |
| `-o <file>` | Write full results as JSON to `<file>` | none |
| `-h`, `--help` | Show usage and exit | — |

Sample output:

```
S3 Hunter v3.0 — keyword: mycompany | candidates: 1020 | threads: 10 | inspect: on

[FOUND - PUBLIC]  mycompany-backup   (200)
  listable objects (top 20):
    - backups/2024-01-01.tar.gz
    - backups/2024-02-01.tar.gz
  exposure: ACL grants WRITE to AllUsers (anyone can upload/overwrite objects);
[FOUND - PRIVATE] mycompany-dev      (403)

Done.
```

`--inspect` never downloads object contents and never modifies a bucket — it only reads the bucket's own listing/ACL/policy metadata, all via unauthenticated GET requests. Findings should still be handled per responsible-disclosure norms for whatever program you're testing under.

---

### Requirements

- bash + `curl`

### Install

```
git clone https://github.com/Venu-exe/s3-toolkit.git
cd s3-toolkit
chmod +x *.sh
```

---

`[System Ready]` Made by [Venu-exe](https://github.com/Venu-exe)

### License

MIT