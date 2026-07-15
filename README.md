# S3 Toolkit

A small set of bash scripts for working with AWS S3 buckets: searching your own buckets, checking bucket status, and enumerating bucket names for recon.

> ⚠️ **Use `s3-hunter.sh` only against domains/keywords you own or are explicitly authorized to test.** Unauthorized scanning of third-party infrastructure may violate acceptable-use policies or the law.

## Scripts

### `s3-finder.sh`
Search your own S3 buckets/objects by name pattern, with an interactive menu, presets, and domain-search mode. Requires AWS CLI (configured) and `jq`.

```bash
./s3-finder.sh                       # interactive menu
./s3-finder.sh invoice                # search all buckets for "invoice"
./s3-finder.sh -d example.com         # domain mode
./s3-finder.sh --preset invoices
```

### `s3-status.sh`
Quick check of whether a bucket name is reachable — prints the HTTP status code (200/403/404) to the screen. No AWS credentials needed.

```bash
./s3-status.sh my-bucket
./s3-status.sh bucket1 bucket2 bucket3
./s3-status.sh -f buckets.txt
```

### `s3-hunter.sh`
lazys3-style bucket enumeration. Generates common bucket-name permutations for a keyword and checks each against S3 in parallel.

```bash
./s3-hunter.sh mycompany
./s3-hunter.sh mycompany -w common-bucket-words.txt -t 20
```

### `common-bucket-words.txt`
Wordlist of common bucket-naming patterns (dev, prod, backup, staging, etc.) for use with `s3-hunter.sh -w`.

## Requirements
- bash
- `curl`
- AWS CLI v2 + `jq` (only needed for `s3-finder.sh`)

## License
MIT
