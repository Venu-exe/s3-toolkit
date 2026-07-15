<h1 align="center">S3 Toolkit</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white" />
  <img src="https://img.shields.io/badge/AWS%20S3-232F3E?style=for-the-badge&logo=amazons3&logoColor=white" />
  <img src="https://img.shields.io/badge/status-active-brightgreen?style=for-the-badge" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=for-the-badge" />
</p>

<p align="center">
Bash tools for working with S3 buckets — search your own buckets, check any bucket's status, and enumerate bucket names for recon.
</p>

---

### ⚠️ Scope & Ethics

Only run `s3-hunter.sh` against domains/keywords **you own or are explicitly authorized to test** (e.g. in-scope for a bug bounty program). Unauthorized scanning of third-party infrastructure may violate acceptable-use policies or the law.

**Ethical Hacking Only** · **Responsible Disclosure** · **No Harm. Just Protection.**

---

### Arsenal

| Tool | What it does | Needs AWS account? |
|---|---|---|
| `s3-finder.sh` | Search **your own** buckets/objects by pattern — interactive menu, presets, domain-search mode | ✅ Yes |
| `s3-status.sh` | Check if a bucket name is reachable — prints HTTP status (200/403/404) | ❌ No |
| `s3-hunter.sh` | lazys3-style enumeration — generates bucket-name permutations for a keyword and checks each in parallel | ❌ No |
| `common-bucket-words.txt` | 170-word list of common bucket-naming patterns for `s3-hunter.sh -w` | — |

---

### Usage

**s3-finder.sh** — search your own AWS account
```bash
./s3-finder.sh                       # interactive menu
./s3-finder.sh invoice                # search all buckets for "invoice"
./s3-finder.sh -d example.com         # domain mode
./s3-finder.sh --preset invoices
```

**s3-status.sh** — quick reachability check, no AWS account needed
```bash
./s3-status.sh my-bucket
./s3-status.sh bucket1 bucket2 bucket3
./s3-status.sh -f buckets.txt
```

**s3-hunter.sh** — bucket name recon
```bash
./s3-hunter.sh mycompany
./s3-hunter.sh mycompany -w common-bucket-words.txt -t 20
```

Sample output:
```
S3 Hunter — keyword: mycompany  |  candidates: 1020  |  threads: 10

[FOUND - PUBLIC]  mycompany-backup   (200)
[FOUND - PRIVATE] mycompany-dev      (403)

Done.
```

---

### Requirements
- bash + `curl`
- AWS CLI v2 + `jq` — only needed for `s3-finder.sh`

### Install
```bash
git clone https://github.com/Venu-exe/s3-toolkit.git
cd s3-toolkit
chmod +x *.sh
```

---

<p align="center">
`[System Ready]` Made by <a href="https://github.com/Venu-exe">Venu-exe</a>
</p>

### License
MIT
