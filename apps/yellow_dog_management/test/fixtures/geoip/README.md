# GeoIP test artifact

`GeoIP2-City-Test.mmdb.base64` contains the unmodified 22,569-byte public MaxMind
test database encoded as Base64. Test helpers decode it into disposable MMDB
files; no database downloads are needed during tests.

- Source: https://github.com/maxmind/MaxMind-DB/blob/276926d23b4109ca5452709bfb5931c338afb34c/test-data/GeoIP2-City-Test.mmdb
- Repository revision: `276926d23b4109ca5452709bfb5931c338afb34c`
- Original binary SHA-256: `ed972738e4e03a3e56e12041a6af4d91592249d110f7e4a647e5f2fa0e639c09`
- Retrieved: 2026-10-01
- License: MIT, selected from the upstream Apache-2.0/MIT dual license.
- Copyright (c) 2013–2026 MaxMind, Inc.; attribution from the upstream README.

This is synthetic test data, not an operational geolocation database. The same
fixture exercises both configured slots; the metadata accurately identifies it
as `GeoIP2-City`. No claim is made that it is a separate Country database.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
