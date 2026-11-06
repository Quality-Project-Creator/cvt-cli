# Attribution

CVT (`cvt-cli`) is a file format converter that reuses mature open source
implementations instead of reimplementing codecs. This project's own source
code is licensed under the MIT License; see `LICENSE` for the full text.

Every direct dependency and every external engine is recorded in the tables
below with its upstream URL, license, usage mode, the CVT files that use it,
and notes on the integration.

## Reference modes

| Usage mode | Meaning |
| --- | --- |
| `runtime-gem` | A gem declared as a runtime dependency in `cvt-cli.gemspec` and required by one or more backends. |
| `shared-library` | A user-installed library loaded at runtime by a permissively licensed gem through FFI (dynamic linking only; no source copied, no static linkage, no redistribution). |
| `adapted-code` | A project whose documented public API or algorithm informed an adapter without copying source code. |
| `subprocess-engine` | An external program invoked as a separate process through `Cvt::Shell` with an argv array. |

## Direct references

| Project | Upstream URL | License | Usage mode | Local files | Notes |
| --- | --- | --- | --- | --- | --- |
| rails/marcel | https://github.com/rails/marcel | Apache-2.0 | runtime-gem | lib/cvt/detector.rb | MIME magic detection. Loaded lazily; `--version` does not load it, while `--formats` may probe backend availability. |
| rubyzip/rubyzip | https://github.com/rubyzip/rubyzip | BSD-2-Clause | runtime-gem | lib/cvt/backends/native_archive.rb, lib/cvt/adapters/archive/ | ZIP entry read and write for archive routes. CVT adds its own path safety checks around it. |
| libvips/ruby-vips | https://github.com/libvips/ruby-vips | MIT | runtime-gem | lib/cvt/backends/vips.rb | Ruby binding for the raster image backend. It uses a user-installed libvips shared library, which this gem does not bundle. |
| minimagick/minimagick | https://github.com/minimagick/minimagick | MIT | runtime-gem | lib/cvt/backends/imagemagick.rb | Wrapper around the ImageMagick CLI for BMP, PNM, TGA, ICO, GIF, and the SVG fallback. |
| yob/pdf-reader | https://github.com/yob/pdf-reader | MIT | runtime-gem | lib/cvt/backends/pdf.rb | Pure Ruby PDF text extraction. Poppler `pdftotext` is the fallback. |
| prawnpdf/prawn | https://github.com/prawnpdf/prawn | Ruby License, with GPLv2 and GPLv3 alternatives | runtime-gem | lib/cvt/backends/pdf.rb | Tri-licensed project. CVT uses it under the Ruby License option for image to PDF output. |
| caxlsx/caxlsx | https://github.com/caxlsx/caxlsx | MIT | runtime-gem | lib/cvt/backends/spreadsheet.rb | XLSX writing with a single `Sheet1` worksheet. |
| roo-rb/roo | https://github.com/roo-rb/roo | MIT | runtime-gem | lib/cvt/backends/spreadsheet.rb | XLSX and ODS reading, including `--sheet` selection. |
| gettalong/kramdown | https://github.com/gettalong/kramdown | MIT | runtime-gem | lib/cvt/backends/native_text.rb | Markdown to HTML conversion for native text routes. |
| sparklemotion/nokogiri | https://github.com/sparklemotion/nokogiri | MIT | runtime-gem | lib/cvt/backends/native_text.rb, lib/cvt/backends/native_data.rb | HTML and XML parsing for text and data conversions. |
| emancu/toml-rb | https://github.com/emancu/toml-rb | MIT | runtime-gem | lib/cvt/backends/native_data.rb | TOML read and write for table shape conversions. |
| cpetersen/srt | https://github.com/cpetersen/srt | MIT | runtime-gem | lib/cvt/backends/native_subtitle.rb | SRT parsing into the shared cue model. VTT and ASS use the built-in adapter. |

## Subprocess engines

| Project | Upstream URL | License | Usage mode | Local files | Notes |
| --- | --- | --- | --- | --- | --- |
| ImageMagick/ImageMagick | https://github.com/ImageMagick/ImageMagick | ImageMagick License | subprocess-engine | lib/cvt/backends/imagemagick.rb, lib/cvt/adapters/image/ | Image engine invoked as `magick` on Windows to avoid the `convert.exe` name clash with the system tool. |
| FFmpeg/FFmpeg | https://github.com/FFmpeg/FFmpeg | LGPL-2.1+, with GPL components only in a GPL build | subprocess-engine | lib/cvt/backends/ffmpeg.rb | Media engine invoked through `ffmpeg` and `ffprobe` argv. GPL-only codecs such as libx264 exist only in a GPL build chosen by the user. |
| jgm/pandoc | https://github.com/jgm/pandoc | GPL-2.0+ | subprocess-engine | lib/cvt/backends/pandoc.rb | Document engine for md, html, docx, odt, rst, tex, and epub routes. |
| LibreOffice/core | https://github.com/LibreOffice/core | MPL-2.0, with LGPL and GPL components | subprocess-engine | lib/cvt/backends/libreoffice.rb | `soffice` runs with an isolated temporary UserInstallation profile. Mixed-license project; invoked only as a separate process. |
| kovidgoyal/calibre | https://github.com/kovidgoyal/calibre | GPL-3.0 | subprocess-engine | lib/cvt/backends/calibre.rb | Optional ebook engine via `ebook-convert`. Never assumed to be installed; tests skip when it is missing. |
| Poppler | https://poppler.freedesktop.org/ | GPL-2.0+ | subprocess-engine | lib/cvt/backends/pdf.rb, lib/cvt/adapters/pdf/ | PDF engine via `pdftotext` and `pdftoppm`. Fallback for text extraction and the primary rasterizer. |
| GNOME/librsvg | https://github.com/GNOME/librsvg | LGPL-2.1+ | subprocess-engine | lib/cvt/backends/rsvg.rb | SVG engine via `rsvg-convert` for SVG to PNG and SVG to PDF. |
| tukaani-project/xz | https://github.com/tukaani-project/xz | Public Domain, with liblzma under 0BSD | subprocess-engine | lib/cvt/backends/native_archive.rb | `xz` CLI for .xz single-stream routes. liblzma is the 0BSD component used by the binary. |
| bzip2 | https://sourceware.org/bzip2/ | bzip2 license | subprocess-engine | lib/cvt/backends/native_archive.rb | `bzip2` CLI for .bz2 single-stream routes. |
| ip7z/7zip | https://github.com/ip7z/7zip | LGPL-2.1+, with the unRAR restriction | subprocess-engine | lib/cvt/backends/native_archive.rb | `7z` fallback for archive routes when xz or bzip2 is missing. |

## Shared library engine

| Project | Upstream URL | License | Usage mode | Local files | Notes |
| --- | --- | --- | --- | --- | --- |
| libvips/libvips | https://github.com/libvips/libvips | LGPL-2.1 | shared-library | lib/cvt/backends/vips.rb, lib/cvt/adapters/image/ | Image engine loaded by the MIT ruby-vips gem through FFI from a user-installed shared library. It is not a subprocess. CVT does not bundle, modify, or distribute libvips; this is dynamic use under the standard LGPL-2.1 relinkable-shared-library conditions, and the user may replace the library with a modified build. |

## License compliance

- No copyleft source code is copied into this project.
- All 12 direct references are permissively licensed (MIT, BSD-2-Clause,
  Apache-2.0, or the Ruby License), so they may be used as runtime gems
  without copyleft obligations beyond preserving their notices.
- Prawn is offered under a tri-license (Ruby License, GPLv2, GPLv3). CVT
  uses it under the Ruby License option, not the GPL options.
- Copyleft engine source code is never copied, bundled, or vendored into
  this project. GPL, AGPL, and LGPL engines other than libvips run only as
  separate processes through `Cvt::Shell` argv arrays, and the user installs
  them separately.
- libvips is the one exception to process isolation. The MIT ruby-vips gem
  loads a user-installed libvips shared library through FFI at runtime, so
  libvips is classified as `shared-library`, not `subprocess-engine`. CVT
  does not bundle, modify, or distribute libvips, and the standard LGPL-2.1
  relinkable-shared-library conditions are met because the user supplies the
  library and can substitute a modified build.
- No engine binary is bundled, vendored, or distributed with the gem. Users
  install each engine themselves and remain bound by that engine's license.
- The MIT License for CVT's own code permits use, modification, and
  redistribution with the copyright and permission notice preserved in
  `LICENSE`.
