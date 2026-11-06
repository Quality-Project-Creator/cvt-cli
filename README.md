# CVT

A single-command file format converter. 56 formats, 13 backends, stable
YAML output, and a predictable exit code.

CVT does not reimplement codecs. It routes each conversion to the best
available implementation already on your machine: native Ruby gems for
text, data, spreadsheets, PDF, subtitles and archives, plus
subprocess engines such as libvips, ImageMagick, FFmpeg, Pandoc,
LibreOffice, Calibre, Poppler and librsvg when they are installed. If an
engine is missing, CVT reports which route is unavailable instead of
failing halfway through a conversion.

Version: `0.0.1-beta`.

## Requirements

- Ruby 3.1 or newer.
- Optional engines, installed per platform:

  | Engine | Used for | Override |
  | --- | --- | --- |
  | libvips | Raster images (AVIF, HEIC, TIFF, ...) | `CVT_BIN_VIPS` |
  | ImageMagick | BMP, PNM, TGA, ICO, GIF, SVG fallback | `CVT_BIN_MAGICK` |
  | FFmpeg / ffprobe | Audio and video | `CVT_BIN_FFMPEG`, `CVT_BIN_FFPROBE` |
  | Pandoc | Markdown, HTML, DOCX, ODT, RST, LaTeX, EPUB | `CVT_BIN_PANDOC` |
  | LibreOffice | Office document routes | `CVT_BIN_SOFFICE` |
  | Calibre | AZW3, MOBI, EPUB | `CVT_BIN_EBOOK_CONVERT` |
  | Poppler | PDF text and PDF rasterization | `CVT_BIN_PDFTOTEXT`, `CVT_BIN_PDFTOPPM` |
  | librsvg | SVG to PNG and PDF | `CVT_BIN_RSVG_CONVERT` |
  | xz, bzip2, 7z | Single-stream and archive routes | `CVT_BIN_XZ`, `CVT_BIN_BZIP2`, `CVT_BIN_7Z` |

  Run `cvt --doctor` to see what is detected on this machine, and
  `cvt --backends --available` to list usable backends.

## Install

```sh
gem build cvt-cli.gemspec
gem install ./cvt-cli-0.0.1.pre.beta.gem
```

RubyGems normalizes the prerelease tag, so the gem reports version
`0.0.1.pre.beta` while `cvt --version` prints `0.0.1-beta`.

## Usage

```sh
cvt SOURCE TARGET              # format comes from the file extension
cvt SOURCE --to FORMAT         # explicit output format
cvt SOURCE TARGET --from FORMAT
```

Examples:

```sh
cvt report.docx report.pdf
cvt song.wav song.mp3 --bitrate 128k
cvt sheet.xlsx sheet.csv --sheet "Q3"
cvt scan.pdf page.png --page 2 --dpi 200
cvt README.md README.html
cvt bundle/ bundle.tar.gz
cvt photo.heic photo.jpg --quality 90 --width 1920
cvt --dry-run input.epub output.mobi   # show the route without writing
```

Every successful run prints YAML:

```yaml
ok: true
version: 0.0.1-beta
operation: convert
input:
  path: sample.csv
  format: csv
  bytes: 28
output:
  path: sample.json
  format: json
  bytes: 97
route:
- backend: native_data
  from: csv
  to: json
options: {}
timing:
  total_ms: 342
warnings: []
```

Use `-q` to suppress output for scripts, or parse it directly: the shape
is part of the contract and does not change between releases without a
version bump.

### Formats

```sh
cvt --formats                    # all 56 formats
cvt --format pdf                 # details for one format
cvt --category image             # filter by category
```

| Category | Formats |
| --- | --- |
| archive | 6 |
| audio | 8 |
| data | 9 |
| document | 12 |
| image | 12 |
| subtitle | 3 |
| video | 6 |

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 2 | Usage error |
| 3 | Unsupported conversion |
| 4 | Backend missing |
| 5 | Unreadable or undetected input |
| 6 | Output exists (use `-f` to overwrite) |
| 7 | Conversion failure |
| 8 | Timeout |
| 130 | Interrupted |

## Development

```sh
bundle install
bundle exec rake test        # core suite; engine-dependent tests skip
CVT_INTEGRATION=1 bundle exec rake test
```

CI runs the core suite on Linux, macOS and Windows with Ruby 3.1 and 3.4,
plus an integration job on Ubuntu with engine packages installed.

## License

MIT. See `LICENSE`.

CVT reuses other open source projects as gems, shared libraries and
subprocess engines. Upstream URLs, licenses and integration notes are
listed in `ATTRIBUTION.md`.
