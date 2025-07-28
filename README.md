# czar

clean-room implementation of a [XAR](https://en.wikipedia.org/wiki/Xar_%28archiver%29) unarchiver

## status

- [ ] Header
	- [x] Magic
	- [x] Header size
	- [x] Version
	- [x] TOC length (compressed)
	- [x] TOC length (uncompressed)
	- [ ] Checksum algorithm
		- [x] None
		- [x] SHA1
		- [x] MD5
		- [ ] Custom
- [x] TOC
	- [x] Extraction
	- [x] Parsing
- [ ] Heap
	- [ ] Extraction
		- [ ] gzip
		- [ ] bzip2

## current features

- archive info
- file listing

---

This project, initially authored by Mara Robin Broda in 2018, is licensed under the GNU Lesser General Public License v3.0
