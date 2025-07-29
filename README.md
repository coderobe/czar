# czar

clean-room implementation of a [XAR](https://en.wikipedia.org/wiki/Xar_%28archiver%29) unarchiver

## status

- [x] Header
	- [x] Magic
	- [x] Header size
	- [x] Version
	- [x] TOC length (compressed)
	- [x] TOC length (uncompressed)
	- [x] Checksum algorithm
		- [x] None
		- [x] SHA1
		- [x] MD5
- [x] TOC
	- [x] Extraction
	- [x] Parsing
	- [x] Checksum validation
- [x] Heap
	- [x] Extraction
		- [x] gzip/zlib
		- [x] bzip2
	- [x] Checksum validation
- [ ] File Metadata

## current features

- archive info
- file listing
- checksum validation
- decompression

## usage

```
Usage: czar [options] <xar_file>
Options:
  --strict      Fail extraction if any checksum validation fails
  --no-extract  Only validate checksums, don't extract files
  --help, -h    Show this help message
```

Files are extracted to `./<xar_file>.extracted/`

### examples

```bash
# Extract archive with checksum validation
./czar archive.xar

# Validate checksums only (no extraction)
./czar --no-extract archive.xar

# Strict mode - fail if any checksum is invalid
./czar --strict archive.xar
```

---

This project, initially authored by Mara Robin Broda in 2018, is licensed under the GNU Lesser General Public License v3.0
