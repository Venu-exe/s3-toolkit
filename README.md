<h1 align="center">S3 Toolkit</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white" />
  <img src="https://img.shields.io/badge/AWS%20S3-232F3E?style=for-the-badge&logo=amazons3&logoColor=white" />
  <img src="https://img.shields.io/badge/status-active-brightgreen?style=for-the-badge" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=for-the-badge" />
</p>

<p align="center">
Bash tools for working with S3 buckets — enumerate bucket names for recon.
</p>

---

### ⚠️ Scope & Ethics

Only run `s3-hunter.sh` against domains/keywords **you own or are explicitly authorized to test** (e.g. in-scope for a bug bounty program). Unauthorized scanning of third-party infrastructure may violate acceptable-use policies or the law.

**Ethical Hacking Only** · **Responsible Disclosure** · **No Harm. Just Protection.**

---

### Arsenal

| Tool | What it does | Needs AWS account? |
|---|---|---|
| `s3-hunter.sh` | lazys3-style enumeration — generates bucket-name permutations for a keyword and checks each in parallel | ❌ No |
| `common-bucket-words.txt` | 170-word list of common bucket-naming patterns for `s3-hunter.sh -w` | — |

---

### Usage

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
